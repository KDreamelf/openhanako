package controller

import (
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/ph01auth"
	"github.com/gin-contrib/sessions"
	"github.com/gin-gonic/gin"
	geoip2 "github.com/oschwald/geoip2-golang"
)

const (
	ph01GatewayLoginPurpose  = "ph01_ai_gateway_login"
	ph01ChallengeTTLSeconds  = int64(5 * 60)
	ph01ChallengeMaxStoreAge = int64(30 * 60)
)

type PH01SignedLoginRequest struct {
	UserID         uint64 `json:"user_id"`
	Nonce          string `json:"nonce"`
	Challenge      string `json:"challenge,omitempty"`
	Signature      string `json:"signature"`
	SignatureHex   string `json:"signature_hex"`
	normalizedSign string
}

type PH01LoginChallenge struct {
	Version     int    `json:"version"`
	Purpose     string `json:"purpose"`
	ChallengeID string `json:"challenge_id"`
	Nonce       string `json:"nonce"`
	IP          string `json:"ip"`
	IPLocation  string `json:"ip_location"`
	UserAgent   string `json:"ua"`
	IssuedAt    int64  `json:"issued_at"`
	ExpiresAt   int64  `json:"expires_at"`
}

type PH01InternalUserSyncRequest struct {
	PH01UserID    uint64 `json:"ph01_user_id"`
	Username      string `json:"username"`
	Nickname      string `json:"nickname,omitempty"`
	Email         string `json:"email,omitempty"`
	Tier          string `json:"tier,omitempty"`
	PubkeyHash    string `json:"pubkey_hash"`
	PowVerified   bool   `json:"pow_verified,omitempty"`
	PowAlgorithm  string `json:"pow_algorithm,omitempty"`
	PowScore      int    `json:"pow_score,omitempty"`
	PowVerifiedAt int64  `json:"pow_verified_at,omitempty"`
}

type PH01InternalChannelRevokeRequest struct {
	PH01UserID    uint64 `json:"ph01_user_id"`
	Username      string `json:"username,omitempty"`
	Reason        string `json:"reason,omitempty"`
	OldPubkeyHash string `json:"old_pubkey_hash,omitempty"`
	NewPubkeyHash string `json:"new_pubkey_hash,omitempty"`
	EffectiveAt   int64  `json:"effective_at,omitempty"`
}

type ph01PendingChallenge struct {
	mu                sync.Mutex
	Challenge         PH01LoginChallenge
	Encoded           string
	Completed         bool
	GatewayUserID     int
	PubkeyHash        string
	AuthUserID        uint64
	AuthUsername      string
	AuthTier          string
	AuthPowVerified   bool
	AuthPowAlgorithm  string
	AuthPowScore      int
	AuthPowVerifiedAt int64
	CompletedAt       int64
	CompletionError   string
}

var (
	ph01PendingChallenges sync.Map
	ph01GeoIPCache        sync.Map
	ph01GeoIPDBMu         sync.Mutex
	ph01GeoIPDBReader     *geoip2.Reader
	ph01GeoIPDBPath       string
	ph01CleanupMu         sync.Mutex
	ph01LastCleanup       int64
)

func PH01CreateChallenge(c *gin.Context) {
	now := common.GetTimestamp()
	cleanupExpiredPH01Challenges(now)

	nonce, err := common.GenerateRandomCharsKey(32)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	clientIP := ph01ClientIP(c)
	challenge := PH01LoginChallenge{
		Version:     1,
		Purpose:     ph01GatewayLoginPurpose,
		ChallengeID: nonce,
		Nonce:       nonce,
		IP:          clientIP,
		IPLocation:  lookupPH01IPLocation(clientIP),
		UserAgent:   c.Request.UserAgent(),
		IssuedAt:    now,
		ExpiresAt:   now + ph01ChallengeTTLSeconds,
	}
	encoded, err := encodePH01Challenge(challenge)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	record := &ph01PendingChallenge{
		Challenge: challenge,
		Encoded:   encoded,
	}
	if err := storePH01PendingChallenge(record); err != nil {
		common.ApiError(c, err)
		return
	}

	common.ApiSuccess(c, gin.H{
		"challenge":    encoded,
		"challenge_id": nonce,
		"nonce":        nonce,
		"expires_at":   challenge.ExpiresAt,
		"detail":       challenge,
		"protocol_url": buildPH01ProtocolURL(c, encoded, nonce),
	})
}

func PH01Login(c *gin.Context) {
	completePH01Login(c, true)
}

func PH01ProtocolComplete(c *gin.Context) {
	completePH01Login(c, false)
}

func PH01ChallengeStatus(c *gin.Context) {
	challengeID := strings.TrimSpace(c.Param("id"))
	if challengeID == "" {
		challengeID = strings.TrimSpace(c.Query("challenge_id"))
	}
	if challengeID == "" {
		common.ApiError(c, errors.New("missing PH01 challenge id"))
		return
	}

	record, err := getPH01PendingChallenge(challengeID)
	if err != nil {
		common.ApiError(c, err)
		return
	}

	record.mu.Lock()
	completed := record.Completed
	completionError := record.CompletionError
	userID := record.GatewayUserID
	authResp := &ph01auth.VerifySignatureResponse{
		Valid:         true,
		UserID:        record.AuthUserID,
		Username:      record.AuthUsername,
		Tier:          record.AuthTier,
		PowVerified:   record.AuthPowVerified,
		PowAlgorithm:  record.AuthPowAlgorithm,
		PowScore:      record.AuthPowScore,
		PowVerifiedAt: record.AuthPowVerifiedAt,
	}
	record.mu.Unlock()

	if completionError != "" {
		common.ApiErrorMsg(c, completionError)
		return
	}
	if !completed {
		common.ApiSuccess(c, gin.H{"status": "pending"})
		return
	}

	user, err := model.GetUserById(userID, false)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	identity, err := model.GetPH01IdentityByUserID(user.Id)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	deletePH01PendingChallenge(challengeID)
	setupPH01LoginSession(c, user, identity, authResp)
}

func PH01VerifyPubkeys(c *gin.Context) {
	var req ph01auth.VerifyPubkeysRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		common.ApiError(c, err)
		return
	}
	resp, err := ph01auth.NewFromEnv().VerifyPubkeys(c.Request.Context(), req)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	common.ApiSuccess(c, resp)
}

func PH01InternalSyncUser(c *gin.Context) {
	if !verifyPH01InternalToken(c) {
		return
	}
	var req PH01InternalUserSyncRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": err.Error()})
		return
	}
	req.Username = strings.TrimSpace(req.Username)
	req.PubkeyHash = strings.ToLower(strings.TrimSpace(req.PubkeyHash))
	if req.PH01UserID == 0 || req.Username == "" {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "invalid PH01 user"})
		return
	}
	if len([]rune(req.Username)) > model.UserNameMaxLength {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "PH01 username too long"})
		return
	}
	if req.PubkeyHash == "" {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "pubkey_hash required"})
		return
	}
	gatewayUser, identity, err := model.FindOrCreateUserFromPH01State(model.PH01UserState{
		PH01UserID:    req.PH01UserID,
		PH01Username:  req.Username,
		PubkeyHash:    req.PubkeyHash,
		PowVerified:   req.PowVerified,
		PowAlgorithm:  req.PowAlgorithm,
		PowScore:      req.PowScore,
		PowVerifiedAt: req.PowVerifiedAt,
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": err.Error()})
		return
	}
	common.ApiSuccess(c, gin.H{
		"user_id":       gatewayUser.Id,
		"username":      gatewayUser.Username,
		"ph01_user_id":  identity.PH01UserID,
		"ph01_username": identity.PH01Username,
	})
}

func PH01InternalRevokeChannels(c *gin.Context) {
	if !verifyPH01InternalToken(c) {
		return
	}
	var req PH01InternalChannelRevokeRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": err.Error()})
		return
	}
	if req.PH01UserID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "ph01_user_id required"})
		return
	}
	revoked, err := ph01RevokeChannelsForUser(req.PH01UserID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": err.Error()})
		return
	}
	common.ApiSuccess(c, gin.H{
		"ph01_user_id":    req.PH01UserID,
		"revoked_count":   revoked,
		"reason":          strings.TrimSpace(req.Reason),
		"effective_at":    req.EffectiveAt,
		"old_pubkey_hash": strings.ToLower(strings.TrimSpace(req.OldPubkeyHash)),
		"new_pubkey_hash": strings.ToLower(strings.TrimSpace(req.NewPubkeyHash)),
	})
}

func completePH01Login(c *gin.Context, attachBrowserSession bool) {
	var req PH01SignedLoginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		common.ApiError(c, err)
		return
	}
	if err := req.normalize(); err != nil {
		common.ApiError(c, err)
		return
	}
	record, err := resolvePH01LoginChallenge(c, req.Nonce, req.Challenge)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	challenge := record.Challenge

	authResp, err := ph01auth.NewFromEnv().VerifyChallengeSignature(c.Request.Context(), ph01auth.VerifyChallengeSignatureRequest{
		UserID:       req.UserID,
		Challenge:    record.Encoded,
		SignatureHex: req.normalizedSign,
	})
	if err != nil {
		common.ApiError(c, err)
		return
	}
	if !authResp.Valid {
		markPH01ChallengeError(record, "PH01 authentication failed: "+authResp.Error)
		_ = storePH01PendingChallenge(record)
		common.ApiErrorMsg(c, "PH01 authentication failed: "+authResp.Error)
		return
	}
	if authResp.UserID != req.UserID {
		markPH01ChallengeError(record, "PH01 authentication failed: user_id mismatch")
		_ = storePH01PendingChallenge(record)
		common.ApiError(c, errors.New("PH01 authentication user id mismatch"))
		return
	}
	if strings.TrimSpace(authResp.PubkeyHash) == "" {
		markPH01ChallengeError(record, "PH01 authentication failed: missing pubkey hash")
		_ = storePH01PendingChallenge(record)
		common.ApiError(c, errors.New("PH01 authentication pubkey hash missing"))
		return
	}
	pubkeyHash := strings.ToLower(strings.TrimSpace(authResp.PubkeyHash))
	gatewayUser, identity, err := model.FindOrCreateUserFromPH01State(model.PH01UserState{
		PH01UserID:    authResp.UserID,
		PH01Username:  authResp.Username,
		PubkeyHash:    pubkeyHash,
		PowVerified:   authResp.PowVerified,
		PowAlgorithm:  authResp.PowAlgorithm,
		PowScore:      authResp.PowScore,
		PowVerifiedAt: authResp.PowVerifiedAt,
	})
	if err != nil {
		common.ApiError(c, err)
		return
	}
	if gatewayUser.Status != common.UserStatusEnabled {
		common.ApiErrorMsg(c, "gateway user disabled")
		return
	}
	markPH01ChallengeComplete(record, gatewayUser, authResp, pubkeyHash)
	if err := storePH01PendingChallenge(record); err != nil {
		common.ApiError(c, err)
		return
	}
	if attachBrowserSession {
		deletePH01PendingChallenge(challenge.Nonce)
		setupPH01LoginSession(c, gatewayUser, identity, authResp)
		return
	}
	common.ApiSuccess(c, gin.H{
		"status":       "accepted",
		"challenge_id": challenge.ChallengeID,
	})
}

func verifyPH01InternalToken(c *gin.Context) bool {
	expected := strings.TrimSpace(os.Getenv("PH01_AUTH_INTERNAL_TOKEN"))
	if expected == "" {
		c.JSON(http.StatusServiceUnavailable, gin.H{"success": false, "message": "PH01 internal token not configured"})
		return false
	}
	got := strings.TrimSpace(c.GetHeader("X-PH01-Internal-Token"))
	if got == "" {
		header := strings.TrimSpace(c.GetHeader("Authorization"))
		if strings.HasPrefix(header, "Bearer ") {
			got = strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))
		}
	}
	if got == "" || subtle.ConstantTimeCompare([]byte(got), []byte(expected)) != 1 {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "invalid PH01 internal token"})
		return false
	}
	return true
}

func (r *PH01SignedLoginRequest) normalize() error {
	r.normalizedSign = strings.ToLower(strings.TrimSpace(r.Signature))
	if r.normalizedSign == "" {
		r.normalizedSign = strings.ToLower(strings.TrimSpace(r.SignatureHex))
	}
	r.Nonce = strings.TrimSpace(r.Nonce)
	r.Challenge = strings.TrimSpace(r.Challenge)
	if r.UserID == 0 || r.Nonce == "" || r.normalizedSign == "" {
		return errors.New("invalid PH01 login authorization")
	}
	return nil
}

func resolvePH01LoginChallenge(c *gin.Context, nonce string, encoded string) (*ph01PendingChallenge, error) {
	challengeID := strings.TrimSpace(nonce)
	if challengeID == "" {
		challengeID = strings.TrimSpace(c.Query("nonce"))
	}
	if challengeID == "" {
		challengeID = strings.TrimSpace(c.Query("challenge_id"))
	}
	if encoded != "" {
		challenge, err := decodePH01Challenge(encoded)
		if err != nil {
			return nil, err
		}
		if challengeID == "" {
			challengeID = challenge.Nonce
		}
		if challenge.Nonce != challengeID {
			return nil, errors.New("PH01 challenge nonce mismatch")
		}
	}
	if challengeID == "" {
		return nil, errors.New("missing PH01 challenge nonce")
	}
	record, err := getPH01PendingChallenge(challengeID)
	if err != nil {
		return nil, err
	}
	if encoded != "" && encoded != record.Encoded {
		return nil, errors.New("PH01 challenge mismatch")
	}
	return record, nil
}

func encodePH01Challenge(challenge PH01LoginChallenge) (string, error) {
	raw, err := json.Marshal(challenge)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

func decodePH01Challenge(encoded string) (PH01LoginChallenge, error) {
	var challenge PH01LoginChallenge
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil {
		return challenge, err
	}
	if err := json.Unmarshal(raw, &challenge); err != nil {
		return challenge, err
	}
	return challenge, nil
}

func storePH01PendingChallenge(record *ph01PendingChallenge) error {
	if record == nil || record.Challenge.Nonce == "" {
		return errors.New("invalid PH01 challenge record")
	}
	if common.RedisEnabled && common.RDB != nil {
		raw, err := json.Marshal(record)
		if err != nil {
			return err
		}
		ttl := time.Duration(ph01ChallengeMaxStoreAge) * time.Second
		if remaining := record.Challenge.ExpiresAt - common.GetTimestamp(); remaining > 0 {
			ttl = time.Duration(remaining) * time.Second
		}
		return common.RedisSet(ph01PendingChallengeKey(record.Challenge.Nonce), string(raw), ttl)
	}
	ph01PendingChallenges.Store(record.Challenge.Nonce, record)
	return nil
}

func getPH01PendingChallenge(nonce string) (*ph01PendingChallenge, error) {
	nonce = strings.TrimSpace(nonce)
	if nonce == "" {
		return nil, errors.New("missing PH01 challenge nonce")
	}
	if common.RedisEnabled && common.RDB != nil {
		raw, err := common.RedisGet(ph01PendingChallengeKey(nonce))
		if err != nil {
			return nil, errors.New("PH01 challenge not found")
		}
		var record ph01PendingChallenge
		if err := json.Unmarshal([]byte(raw), &record); err != nil {
			return nil, errors.New("PH01 challenge store corrupted")
		}
		if record.Challenge.ExpiresAt < common.GetTimestamp() {
			deletePH01PendingChallenge(nonce)
			return nil, errors.New("PH01 challenge expired")
		}
		return &record, nil
	}

	value, ok := ph01PendingChallenges.Load(nonce)
	if !ok {
		return nil, errors.New("PH01 challenge not found")
	}
	record, ok := value.(*ph01PendingChallenge)
	if !ok || record == nil {
		return nil, errors.New("PH01 challenge store corrupted")
	}
	if record.Challenge.ExpiresAt < common.GetTimestamp() {
		deletePH01PendingChallenge(nonce)
		return nil, errors.New("PH01 challenge expired")
	}
	return record, nil
}

func deletePH01PendingChallenge(nonce string) {
	nonce = strings.TrimSpace(nonce)
	if nonce == "" {
		return
	}
	if common.RedisEnabled && common.RDB != nil {
		_ = common.RedisDel(ph01PendingChallengeKey(nonce))
		return
	}
	ph01PendingChallenges.Delete(nonce)
}

func ph01PendingChallengeKey(nonce string) string {
	return "ph01:login_challenge:" + nonce
}

func markPH01ChallengeComplete(record *ph01PendingChallenge, user *model.User, authResp *ph01auth.VerifySignatureResponse, pubkeyHash string) {
	record.mu.Lock()
	defer record.mu.Unlock()
	record.Completed = true
	record.GatewayUserID = user.Id
	record.PubkeyHash = pubkeyHash
	record.AuthUserID = authResp.UserID
	record.AuthUsername = authResp.Username
	record.AuthTier = authResp.Tier
	record.AuthPowVerified = authResp.PowVerified
	record.AuthPowAlgorithm = authResp.PowAlgorithm
	record.AuthPowScore = authResp.PowScore
	record.AuthPowVerifiedAt = authResp.PowVerifiedAt
	record.CompletedAt = common.GetTimestamp()
	record.CompletionError = ""
}

func markPH01ChallengeError(record *ph01PendingChallenge, msg string) {
	if record == nil {
		return
	}
	record.mu.Lock()
	defer record.mu.Unlock()
	record.CompletionError = msg
}

func cleanupExpiredPH01Challenges(now int64) {
	ph01CleanupMu.Lock()
	defer ph01CleanupMu.Unlock()
	if now-ph01LastCleanup < 60 {
		return
	}
	ph01LastCleanup = now
	ph01PendingChallenges.Range(func(key, value any) bool {
		record, ok := value.(*ph01PendingChallenge)
		if !ok || record == nil || record.Challenge.ExpiresAt+ph01ChallengeMaxStoreAge < now {
			ph01PendingChallenges.Delete(key)
		}
		return true
	})
}

func ph01ClientIP(c *gin.Context) string {
	if strings.EqualFold(strings.TrimSpace(os.Getenv("PH01_TRUST_PROXY_HEADERS")), "true") {
		if ip := firstHeaderIP(c.GetHeader("X-Forwarded-For")); ip != "" {
			return ip
		}
		if ip := firstHeaderIP(c.GetHeader("X-Real-IP")); ip != "" {
			return ip
		}
	}
	return c.ClientIP()
}

func firstHeaderIP(value string) string {
	for _, part := range strings.Split(value, ",") {
		ip := strings.TrimSpace(part)
		if parsed := net.ParseIP(ip); parsed != nil {
			return parsed.String()
		}
	}
	return ""
}

func lookupPH01IPLocation(ip string) string {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return "unknown"
	}
	if parsed.IsLoopback() || parsed.IsPrivate() || parsed.IsUnspecified() {
		return "local/private"
	}
	if cached, ok := ph01LookupCachedGeoLocation(parsed.String()); ok {
		return cached
	}
	if location, ok := lookupPH01IPLocationFromAPI(parsed.String()); ok {
		ph01StoreGeoLocation(parsed.String(), location)
		return location
	}
	if location, ok := lookupPH01IPLocationFromLocalDB(parsed.String()); ok {
		ph01StoreGeoLocation(parsed.String(), location)
		return location
	}
	return "unknown"
}

type ph01GeoIPCacheEntry struct {
	Location  string
	ExpiresAt time.Time
}

func ph01GeoIPCacheTTL() time.Duration {
	raw := strings.TrimSpace(os.Getenv("PH01_GEOIP_CACHE_TTL_HOURS"))
	if raw == "" {
		return 7 * 24 * time.Hour
	}
	hours, err := strconv.Atoi(raw)
	if err != nil || hours <= 0 {
		return 7 * 24 * time.Hour
	}
	return time.Duration(hours) * time.Hour
}

func ph01LookupCachedGeoLocation(ip string) (string, bool) {
	if common.RedisEnabled && common.RDB != nil {
		if cached, err := common.RedisGet(ph01GeoIPCacheKey(ip)); err == nil {
			if cached = strings.TrimSpace(cached); cached != "" {
				return cached, true
			}
		}
	}
	value, ok := ph01GeoIPCache.Load(ip)
	if !ok {
		return "", false
	}
	entry, ok := value.(ph01GeoIPCacheEntry)
	if !ok {
		ph01GeoIPCache.Delete(ip)
		return "", false
	}
	if time.Now().After(entry.ExpiresAt) {
		ph01GeoIPCache.Delete(ip)
		return "", false
	}
	if strings.TrimSpace(entry.Location) == "" {
		return "", false
	}
	return entry.Location, true
}

func ph01StoreGeoLocation(ip, location string) {
	location = strings.TrimSpace(location)
	if location == "" || strings.EqualFold(location, "unknown") {
		return
	}
	ttl := ph01GeoIPCacheTTL()
	if common.RedisEnabled && common.RDB != nil {
		_ = common.RedisSet(ph01GeoIPCacheKey(ip), location, ttl)
	}
	ph01GeoIPCache.Store(ip, ph01GeoIPCacheEntry{
		Location:  location,
		ExpiresAt: time.Now().Add(ttl),
	})
}

func ph01GeoIPCacheKey(ip string) string {
	return "ph01:geoip:" + ip
}

func lookupPH01IPLocationFromAPI(ip string) (string, bool) {
	apiURL := strings.TrimSpace(os.Getenv("PH01_GEOIP_API_URL"))
	if apiURL != "" {
		requestURL := strings.ReplaceAll(apiURL, "{ip}", url.QueryEscape(ip))
		timeoutMS := 800
		if raw := strings.TrimSpace(os.Getenv("PH01_GEOIP_API_TIMEOUT_MS")); raw != "" {
			if parsedTimeout, err := strconv.Atoi(raw); err == nil && parsedTimeout > 0 {
				timeoutMS = parsedTimeout
			}
		}
		client := &http.Client{Timeout: time.Duration(timeoutMS) * time.Millisecond}
		req, err := http.NewRequest(http.MethodGet, requestURL, nil)
		if err != nil {
			return "", false
		}
		resp, err := client.Do(req)
		if err != nil {
			return "", false
		}
		defer resp.Body.Close()
		if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
			return "", false
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		if err != nil {
			return "", false
		}
		if location := ph01ParseGeoLocationPayload(body); location != "" {
			return location, true
		}
	}
	return "", false
}

func ph01ParseGeoLocationPayload(body []byte) string {
	text := strings.TrimSpace(string(body))
	if text == "" {
		return ""
	}
	var geo ph01GeoIPPayload
	if err := json.Unmarshal(body, &geo); err == nil {
		return ph01GeoLocationFromPayload(geo)
	}
	var jsonText string
	if err := json.Unmarshal(body, &jsonText); err == nil {
		text = strings.TrimSpace(jsonText)
	}
	if text != "" {
		return text
	}
	return ""
}

type ph01GeoIPPayload struct {
	Success         *bool             `json:"success"`
	Status          string            `json:"status"`
	Code            any               `json:"code"`
	Country         string            `json:"country"`
	CountryName     string            `json:"country_name"`
	Region          string            `json:"region"`
	RegionName      string            `json:"regionName"`
	RegionNameSnake string            `json:"region_name"`
	Province        string            `json:"province"`
	City            string            `json:"city"`
	Addr            string            `json:"addr"`
	Message         string            `json:"message"`
	Data            *ph01GeoIPPayload `json:"data"`
	IPData          *ph01GeoIPPayload `json:"ipdata"`
	Result          *ph01GeoIPPayload `json:"result"`
}

func ph01GeoLocationFromPayload(geo ph01GeoIPPayload) string {
	if geo.Success != nil && !*geo.Success {
		return ""
	}
	if geo.Status != "" && !ph01GeoIPStatusSuccess(geo.Status) {
		return ""
	}
	if !ph01GeoIPCodeSuccess(geo.Code) {
		return ""
	}

	parts := make([]string, 0, 3)
	if country := firstNonEmptyString(geo.Country, geo.CountryName); country != "" {
		parts = append(parts, country)
	}
	if region := firstNonEmptyString(geo.RegionName, geo.RegionNameSnake, geo.Region, geo.Province); region != "" {
		parts = append(parts, region)
	}
	if city := strings.TrimSpace(geo.City); city != "" {
		parts = append(parts, city)
	}
	if len(parts) > 0 {
		return strings.Join(parts, " / ")
	}

	for _, nested := range []*ph01GeoIPPayload{geo.Data, geo.IPData, geo.Result} {
		if nested == nil {
			continue
		}
		if location := ph01GeoLocationFromPayload(*nested); location != "" {
			return location
		}
	}
	return strings.TrimSpace(geo.Addr)
}

func ph01GeoIPStatusSuccess(status string) bool {
	status = strings.TrimSpace(status)
	return status == "" ||
		strings.EqualFold(status, "success") ||
		strings.EqualFold(status, "ok") ||
		status == "1" ||
		status == "200"
}

func ph01GeoIPCodeSuccess(code any) bool {
	switch value := code.(type) {
	case nil:
		return true
	case float64:
		return value == 0 || value == 1 || value == http.StatusOK
	case string:
		value = strings.TrimSpace(value)
		return value == "" || value == "0" || value == "1" || value == "200"
	default:
		return true
	}
}

func firstNonEmptyString(values ...string) string {
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}

func lookupPH01IPLocationFromLocalDB(ip string) (string, bool) {
	reader, err := ph01LoadGeoIPReader()
	if err != nil || reader == nil {
		return "", false
	}
	record, err := reader.City(net.ParseIP(ip))
	if err != nil {
		return "", false
	}
	parts := make([]string, 0, 3)
	if country := ph01GeoIPCountryLabel(record); country != "" {
		parts = append(parts, country)
	}
	if subdivision := ph01GeoIPSubdivisionLabel(record); subdivision != "" {
		parts = append(parts, subdivision)
	}
	if city := ph01GeoIPCityLabel(record); city != "" {
		parts = append(parts, city)
	}
	if len(parts) == 0 {
		return "", false
	}
	return strings.Join(parts, " / "), true
}

func ph01LoadGeoIPReader() (*geoip2.Reader, error) {
	path := strings.TrimSpace(os.Getenv("PH01_GEOIP_DB_PATH"))
	if path == "" {
		ph01GeoIPDBMu.Lock()
		if ph01GeoIPDBReader != nil {
			_ = ph01GeoIPDBReader.Close()
			ph01GeoIPDBReader = nil
			ph01GeoIPDBPath = ""
		}
		ph01GeoIPDBMu.Unlock()
		return nil, os.ErrNotExist
	}

	ph01GeoIPDBMu.Lock()
	defer ph01GeoIPDBMu.Unlock()

	if ph01GeoIPDBReader != nil && ph01GeoIPDBPath == path {
		return ph01GeoIPDBReader, nil
	}
	if ph01GeoIPDBReader != nil {
		_ = ph01GeoIPDBReader.Close()
		ph01GeoIPDBReader = nil
		ph01GeoIPDBPath = ""
	}

	reader, err := geoip2.Open(path)
	if err != nil {
		return nil, err
	}
	ph01GeoIPDBReader = reader
	ph01GeoIPDBPath = path
	return reader, nil
}

func ph01GeoIPCountryLabel(record *geoip2.City) string {
	if record == nil {
		return ""
	}
	if label := ph01GeoIPLocalizedName(record.Country.Names, record.Country.IsoCode); label != "" {
		return label
	}
	return strings.TrimSpace(record.Country.IsoCode)
}

func ph01GeoIPSubdivisionLabel(record *geoip2.City) string {
	if record == nil || len(record.Subdivisions) == 0 {
		return ""
	}
	subdivision := record.Subdivisions[0]
	if label := ph01GeoIPLocalizedName(subdivision.Names, subdivision.IsoCode); label != "" {
		return label
	}
	return strings.TrimSpace(subdivision.IsoCode)
}

func ph01GeoIPCityLabel(record *geoip2.City) string {
	if record == nil {
		return ""
	}
	if label := ph01GeoIPLocalizedName(record.City.Names, ""); label != "" {
		return label
	}
	return ""
}

func ph01GeoIPLocalizedName(names map[string]string, fallback string) string {
	for _, key := range []string{"zh-CN", "zh", "en"} {
		if value := strings.TrimSpace(names[key]); value != "" {
			return value
		}
	}
	for _, value := range names {
		if label := strings.TrimSpace(value); label != "" {
			return label
		}
	}
	return strings.TrimSpace(fallback)
}

func buildPH01ProtocolURL(c *gin.Context, challenge string, challengeID string) string {
	callbackValues := url.Values{}
	callbackValues.Set("nonce", challengeID)
	callback := publicGatewayBaseURL(c) + "/api/ph01/auth/protocol/complete?" + callbackValues.Encode()
	values := url.Values{}
	values.Set("challenge", challenge)
	values.Set("callback", callback)
	return "ph01://login?" + values.Encode()
}

func publicGatewayBaseURL(c *gin.Context) string {
	if configured := strings.TrimRight(strings.TrimSpace(os.Getenv("PH01_GATEWAY_PUBLIC_BASE_URL")), "/"); configured != "" {
		return configured
	}
	scheme := "http"
	if c.Request.TLS != nil || strings.EqualFold(c.GetHeader("X-Forwarded-Proto"), "https") {
		scheme = "https"
	}
	return scheme + "://" + c.Request.Host
}

func setupPH01LoginSession(c *gin.Context, user *model.User, identity *model.PH01Identity, authResp *ph01auth.VerifySignatureResponse) {
	model.UpdateUserLastLoginAt(user.Id)
	session := sessions.Default(c)
	session.Set("id", user.Id)
	session.Set("username", user.Username)
	session.Set("role", user.Role)
	session.Set("status", user.Status)
	session.Set("group", user.Group)
	if err := session.Save(); err != nil {
		common.ApiError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"message": "",
		"success": true,
		"data": gin.H{
			"id":              user.Id,
			"username":        user.Username,
			"display_name":    user.DisplayName,
			"role":            user.Role,
			"status":          user.Status,
			"group":           user.Group,
			"ph01_user_id":    authResp.UserID,
			"ph01_username":   authResp.Username,
			"ph01_tier":       authResp.Tier,
			"pubkey_hash":     identity.PubkeyHash,
			"pow_verified":    identity.PowVerified,
			"pow_algorithm":   identity.PowAlgorithm,
			"pow_score":       identity.PowScore,
			"pow_verified_at": identity.PowVerifiedAt,
		},
	})
}
