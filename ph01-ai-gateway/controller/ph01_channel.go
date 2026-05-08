package controller

import (
	"bufio"
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/constant"
	"github.com/QuantumNous/new-api/logger"
	"github.com/QuantumNous/new-api/middleware"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/ph01auth"
	"github.com/QuantumNous/new-api/service"
	"github.com/QuantumNous/new-api/setting/ratio_setting"
	"github.com/QuantumNous/new-api/types"
	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"golang.org/x/crypto/hkdf"
)

const (
	ph01ChannelIdleTTL = 10 * time.Minute
	ph01ChannelPrefix  = "ph01:channel:"

	ph01ErrInvalidSignature  = "invalid_signature"
	ph01ErrModelNotAllowed   = "model_not_allowed"
	ph01ErrInvalidChannel    = "invalid_channel"
	ph01ErrDecryptionFailed  = "decryption_failed"
	ph01ErrInvalidPayload    = "invalid_payload"
	ph01ErrInternalError     = "internal_error"
	ph01ErrUserDisabled      = "user_disabled"
	ph01ErrRateLimitExceeded = "rate_limit_exceeded"
	ph01ErrAccessDenied      = "access_denied"
)

type ph01SignedRequest struct {
	Payload      string `json:"payload"`
	PubkeyHex    string `json:"pubkey"`
	SignatureHex string `json:"signature"`
	Timestamp    int64  `json:"timestamp"`
	Nonce        string `json:"nonce"`
}

type ph01HandshakePayload struct {
	EphemeralPubkey string `json:"ephemeral_pubkey"`
}

type ph01EncryptedEnvelope struct {
	ChannelID  string `json:"channel_id"`
	Nonce      string `json:"nonce"`
	Ciphertext string `json:"ciphertext"`
	Tag        string `json:"tag"`
}

type ph01ChatRequest struct {
	Model    string                   `json:"model"`
	Messages []map[string]interface{} `json:"messages"`
	Stream   bool                     `json:"stream"`
	Tools    []map[string]interface{} `json:"tools,omitempty"`
	Extra    map[string]interface{}   `json:"extra,omitempty"`
}

type ph01Channel struct {
	ID            string    `json:"id"`
	GatewayUserID int       `json:"gateway_user_id"`
	PH01UserID    uint64    `json:"ph01_user_id"`
	Username      string    `json:"username"`
	Tier          string    `json:"tier"`
	TokenID       int       `json:"token_id"`
	UsingGroup    string    `json:"using_group"`
	AESKeyHex     string    `json:"aes_key_hex"`
	AllowedModels []string  `json:"allowed_models"`
	CreatedAt     time.Time `json:"created_at"`
	ExpiresAt     time.Time `json:"expires_at"`
}

var ph01Channels sync.Map

func PH01ChannelHandshake(c *gin.Context) {
	var req ph01SignedRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		ph01ProtocolError(c, http.StatusBadRequest, ph01ErrInvalidPayload, err.Error())
		return
	}

	authResp, err := ph01auth.NewFromEnv().VerifySignature(c.Request.Context(), ph01auth.VerifySignatureRequest{
		PubkeyHex:    req.PubkeyHex,
		SignatureHex: req.SignatureHex,
		Payload:      req.Payload,
		Timestamp:    req.Timestamp,
		Nonce:        req.Nonce,
	})
	if err != nil {
		ph01ProtocolError(c, http.StatusBadGateway, ph01ErrInternalError, "auth center: "+err.Error())
		return
	}
	if !authResp.Valid {
		code := strings.TrimSpace(authResp.Error)
		if code == "" {
			code = ph01ErrInvalidSignature
		}
		ph01ProtocolError(c, http.StatusUnauthorized, code, "")
		return
	}

	var payload ph01HandshakePayload
	if err := json.Unmarshal([]byte(req.Payload), &payload); err != nil {
		ph01ProtocolError(c, http.StatusBadRequest, ph01ErrInvalidPayload, err.Error())
		return
	}
	clientPub, err := ph01ParsePubkey(payload.EphemeralPubkey)
	if err != nil {
		ph01ProtocolError(c, http.StatusBadRequest, ph01ErrInvalidPayload, "ephemeral_pubkey: "+err.Error())
		return
	}

	serverPriv, err := secp256k1.GeneratePrivateKey()
	if err != nil {
		ph01ProtocolError(c, http.StatusInternalServerError, ph01ErrInternalError, err.Error())
		return
	}
	aesKey, err := ph01DeriveSharedKey(serverPriv, clientPub)
	if err != nil {
		ph01ProtocolError(c, http.StatusInternalServerError, ph01ErrInternalError, err.Error())
		return
	}

	if strings.TrimSpace(authResp.PubkeyHash) == "" {
		ph01ProtocolError(c, http.StatusBadGateway, ph01ErrInternalError, "auth center response missing pubkey hash")
		return
	}
	gatewayUser, _, err := model.FindOrCreateUserFromPH01(authResp.UserID, authResp.Username, authResp.PubkeyHash)
	if err != nil {
		ph01ProtocolError(c, http.StatusInternalServerError, ph01ErrInternalError, err.Error())
		return
	}
	if gatewayUser.Status != common.UserStatusEnabled {
		ph01ProtocolError(c, http.StatusForbidden, ph01ErrUserDisabled, "")
		return
	}
	carrier, err := model.EnsurePH01DefaultToken(gatewayUser.Id)
	if err != nil {
		ph01ProtocolError(c, http.StatusInternalServerError, ph01ErrInternalError, err.Error())
		return
	}
	allowedModels, usingGroup, err := ph01AllowedModelsForCarrier(gatewayUser.Id, carrier)
	if err != nil {
		ph01ProtocolError(c, http.StatusForbidden, ph01ErrModelNotAllowed, err.Error())
		return
	}

	now := time.Now()
	ch := &ph01Channel{
		ID:            uuid.NewString(),
		GatewayUserID: gatewayUser.Id,
		PH01UserID:    authResp.UserID,
		Username:      authResp.Username,
		Tier:          authResp.Tier,
		TokenID:       carrier.Id,
		UsingGroup:    usingGroup,
		AESKeyHex:     hex.EncodeToString(aesKey),
		AllowedModels: allowedModels,
		CreatedAt:     now,
		ExpiresAt:     now.Add(ph01ChannelIdleTTL),
	}
	if err := ph01StoreChannel(ch); err != nil {
		ph01ProtocolError(c, http.StatusInternalServerError, ph01ErrInternalError, err.Error())
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"channel_id":       ch.ID,
		"ephemeral_pubkey": hex.EncodeToString(serverPriv.PubKey().SerializeUncompressed()),
		"idle_expires_in":  int(ph01ChannelIdleTTL.Seconds()),
		"allowed_models":   allowedModels,
	})
}

func PH01ListModels(c *gin.Context) {
	ch, ok := ph01RequireChannel(c, c.Query("channel_id"))
	if !ok {
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"models": ch.AllowedModels,
		"tier":   ch.Tier,
	})
}

func PH01PublicStoryModels(c *gin.Context) {
	startedAt := time.Now()
	var encryptedChannel *ph01Channel
	var encryptedAESKey []byte
	if c.Request.Method == http.MethodPost {
		rawBody, err := io.ReadAll(c.Request.Body)
		if err != nil {
			ph01ProtocolError(c, http.StatusBadRequest, ph01ErrInvalidPayload, err.Error())
			return
		}
		env, ok := ph01ParseEncryptedEnvelope(rawBody)
		if !ok {
			middleware.PublicStoryAnonymousRateLimit(c)
			if c.IsAborted() {
				return
			}
			ph01ProtocolError(c, http.StatusBadRequest, ph01ErrInvalidPayload, "encrypted envelope required")
			return
		}
		ch, ok := ph01RequireChannel(c, env.ChannelID)
		if !ok {
			return
		}
		aesKey, err := hex.DecodeString(ch.AESKeyHex)
		if err != nil {
			ph01ProtocolError(c, http.StatusInternalServerError, ph01ErrInternalError, err.Error())
			return
		}
		if _, err := ph01DecryptGCM(aesKey, env.Nonce, env.Ciphertext, env.Tag); err != nil {
			ph01ProtocolError(c, http.StatusBadRequest, ph01ErrDecryptionFailed, err.Error())
			return
		}
		encryptedChannel = ch
		encryptedAESKey = aesKey
	}

	_, _, allowedModels, ok := ph01RequireRootPublicStoryCarrier(c, encryptedChannel == nil)
	if !ok {
		return
	}
	logger.LogInfoFields(c.Request.Context(), "ph01_public_story_models_success", map[string]any{
		"layer":           "gateway_handler",
		"operation":       "public_story_models",
		"phase":           "handler",
		"status":          "success",
		"mode":            ph01PublicStoryMode(encryptedChannel != nil),
		"model_count":     len(allowedModels),
		"enforce_ip_rule": encryptedChannel == nil,
		"duration_ms":     time.Since(startedAt).Milliseconds(),
	})
	body := gin.H{
		"models": allowedModels,
		"tier":   "public",
	}
	if encryptedChannel != nil {
		ph01WriteEncryptedJSON(c, encryptedChannel, encryptedAESKey, body)
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"models": allowedModels,
		"tier":   "public",
	})
}

func PH01PublicStoryChat(c *gin.Context) {
	startedAt := time.Now()
	rawBody, err := io.ReadAll(c.Request.Body)
	if err != nil {
		ph01ProtocolError(c, http.StatusBadRequest, ph01ErrInvalidPayload, err.Error())
		return
	}

	relayBody := []byte(nil)
	var chatReq ph01ChatRequest
	var encryptedChannel *ph01Channel
	var encryptedAESKey []byte
	if env, ok := ph01ParseEncryptedEnvelope(rawBody); ok {
		ch, ok := ph01RequireChannel(c, env.ChannelID)
		if !ok {
			return
		}
		aesKey, err := hex.DecodeString(ch.AESKeyHex)
		if err != nil {
			ph01ProtocolError(c, http.StatusInternalServerError, ph01ErrInternalError, err.Error())
			return
		}
		plaintext, err := ph01DecryptGCM(aesKey, env.Nonce, env.Ciphertext, env.Tag)
		if err != nil {
			ph01ProtocolError(c, http.StatusBadRequest, ph01ErrDecryptionFailed, err.Error())
			return
		}
		relayBody, chatReq, err = ph01BuildRelayBody(plaintext)
		if err != nil {
			ph01ProtocolError(c, http.StatusBadRequest, ph01ErrInvalidPayload, err.Error())
			return
		}
		encryptedChannel = ch
		encryptedAESKey = aesKey
	} else {
		middleware.PublicStoryAnonymousRateLimit(c)
		if c.IsAborted() {
			return
		}
		relayBody, chatReq, err = ph01BuildRelayBody(rawBody)
		if err != nil {
			ph01ProtocolError(c, http.StatusBadRequest, ph01ErrInvalidPayload, err.Error())
			return
		}
	}

	if err := ph01ValidatePublicStoryChatRequest(chatReq); err != nil {
		ph01ProtocolError(c, http.StatusBadRequest, ph01ErrInvalidPayload, err.Error())
		return
	}

	carrier, usingGroup, allowedModels, ok := ph01RequireRootPublicStoryCarrier(c, encryptedChannel == nil)
	if !ok {
		return
	}
	if !ph01ModelAllowed(allowedModels, chatReq.Model) {
		ph01ProtocolError(c, http.StatusForbidden, ph01ErrModelNotAllowed, "model "+chatReq.Model+" not allowed")
		return
	}
	if !carrier.UnlimitedQuota && carrier.RemainQuota <= 0 {
		ph01ProtocolError(c, http.StatusTooManyRequests, ph01ErrRateLimitExceeded, "")
		return
	}

	messageCount, messageChars := ph01PublicStoryMessageStats(chatReq.Messages)
	logger.LogInfoFields(c.Request.Context(), "ph01_public_story_chat_relay_start", map[string]any{
		"layer":            "gateway_handler",
		"operation":        "public_story_chat",
		"phase":            "relay",
		"status":           "start",
		"mode":             ph01PublicStoryMode(encryptedChannel != nil),
		"model":            chatReq.Model,
		"message_count":    messageCount,
		"message_chars":    messageChars,
		"request_bytes":    len(relayBody),
		"using_group":      usingGroup,
		"carrier_user_id":  carrier.UserId,
		"carrier_token_id": carrier.Id,
	})
	status, responseBody := ph01RelayChat(c, carrier, usingGroup, relayBody, true)
	if status >= http.StatusBadRequest {
		logger.LogWarnFields(c.Request.Context(), "ph01_public_story_chat_relay_failure", map[string]any{
			"layer":                  "gateway_handler",
			"operation":              "public_story_chat",
			"phase":                  "relay",
			"status":                 "failure",
			"mode":                   ph01PublicStoryMode(encryptedChannel != nil),
			"model":                  chatReq.Model,
			"status_code":            status,
			"upstream_error_preview": ph01LogPreview(string(responseBody), 1200),
			"response_bytes":         len(responseBody),
			"duration_ms":            time.Since(startedAt).Milliseconds(),
		})
		ph01ProtocolError(c, status, ph01ErrInternalError, string(responseBody))
		return
	}
	logger.LogInfoFields(c.Request.Context(), "ph01_public_story_chat_success", map[string]any{
		"layer":          "gateway_handler",
		"operation":      "public_story_chat",
		"phase":          "handler",
		"status":         "success",
		"mode":           ph01PublicStoryMode(encryptedChannel != nil),
		"model":          chatReq.Model,
		"status_code":    status,
		"response_bytes": len(responseBody),
		"duration_ms":    time.Since(startedAt).Milliseconds(),
	})
	if encryptedChannel != nil {
		if err := ph01TouchChannel(encryptedChannel); err != nil {
			common.SysLog("failed to touch PH01 channel: " + err.Error())
		}
		nonceHex, ctHex, tagHex, err := ph01EncryptGCM(encryptedAESKey, responseBody)
		if err != nil {
			ph01ProtocolError(c, http.StatusInternalServerError, ph01ErrInternalError, err.Error())
			return
		}
		c.JSON(http.StatusOK, ph01EncryptedEnvelope{
			ChannelID:  encryptedChannel.ID,
			Nonce:      nonceHex,
			Ciphertext: ctHex,
			Tag:        tagHex,
		})
		return
	}
	c.Data(status, "application/json", responseBody)
}

func ph01WriteEncryptedJSON(c *gin.Context, ch *ph01Channel, aesKey []byte, body gin.H) {
	if err := ph01TouchChannel(ch); err != nil {
		common.SysLog("failed to touch PH01 channel: " + err.Error())
	}
	plaintext, err := common.Marshal(body)
	if err != nil {
		ph01ProtocolError(c, http.StatusInternalServerError, ph01ErrInternalError, err.Error())
		return
	}
	nonceHex, ctHex, tagHex, err := ph01EncryptGCM(aesKey, plaintext)
	if err != nil {
		ph01ProtocolError(c, http.StatusInternalServerError, ph01ErrInternalError, err.Error())
		return
	}
	c.JSON(http.StatusOK, ph01EncryptedEnvelope{
		ChannelID:  ch.ID,
		Nonce:      nonceHex,
		Ciphertext: ctHex,
		Tag:        tagHex,
	})
}

func PH01Chat(c *gin.Context) {
	var env ph01EncryptedEnvelope
	if err := c.ShouldBindJSON(&env); err != nil {
		ph01ProtocolError(c, http.StatusBadRequest, ph01ErrInvalidPayload, err.Error())
		return
	}
	ch, ok := ph01RequireChannel(c, env.ChannelID)
	if !ok {
		return
	}
	aesKey, err := hex.DecodeString(ch.AESKeyHex)
	if err != nil {
		ph01ProtocolError(c, http.StatusInternalServerError, ph01ErrInternalError, err.Error())
		return
	}
	plaintext, err := ph01DecryptGCM(aesKey, env.Nonce, env.Ciphertext, env.Tag)
	if err != nil {
		ph01ProtocolError(c, http.StatusBadRequest, ph01ErrDecryptionFailed, err.Error())
		return
	}

	relayBody, chatReq, err := ph01BuildRelayBody(plaintext)
	if err != nil {
		ph01ProtocolError(c, http.StatusBadRequest, ph01ErrInvalidPayload, err.Error())
		return
	}
	if !ph01ModelAllowed(ch.AllowedModels, chatReq.Model) {
		ph01ProtocolError(c, http.StatusForbidden, ph01ErrModelNotAllowed, "model "+chatReq.Model+" not allowed")
		return
	}

	carrier, err := model.GetTokenById(ch.TokenID)
	if err != nil {
		ph01ProtocolError(c, http.StatusUnauthorized, ph01ErrInvalidChannel, "PH01 carrier key not found")
		return
	}
	if carrier.UserId != ch.GatewayUserID || !model.IsPH01DefaultToken(carrier) {
		ph01ProtocolError(c, http.StatusUnauthorized, ph01ErrInvalidChannel, "PH01 carrier key mismatch")
		return
	}
	if !carrier.UnlimitedQuota && carrier.RemainQuota <= 0 {
		ph01ProtocolError(c, http.StatusTooManyRequests, ph01ErrRateLimitExceeded, "")
		return
	}

	status, responseBody := ph01RelayChat(c, carrier, ch.UsingGroup, relayBody, false)
	if status >= http.StatusBadRequest {
		ph01ProtocolError(c, status, ph01ErrInternalError, string(responseBody))
		return
	}
	if err := ph01TouchChannel(ch); err != nil {
		common.SysLog("failed to touch PH01 channel: " + err.Error())
	}

	if chatReq.Stream {
		ph01WriteEncryptedSSE(c, ch.ID, aesKey, responseBody)
		return
	}
	nonceHex, ctHex, tagHex, err := ph01EncryptGCM(aesKey, responseBody)
	if err != nil {
		ph01ProtocolError(c, http.StatusInternalServerError, ph01ErrInternalError, err.Error())
		return
	}
	c.JSON(http.StatusOK, ph01EncryptedEnvelope{
		ChannelID:  ch.ID,
		Nonce:      nonceHex,
		Ciphertext: ctHex,
		Tag:        tagHex,
	})
}

func ph01RelayChat(c *gin.Context, carrier *model.Token, usingGroup string, relayBody []byte, forceAcceptUnsetRatioModel bool) (int, []byte) {
	originalWriter := c.Writer
	originalBody := c.Request.Body
	originalContentLength := c.Request.ContentLength
	originalPath := c.Request.URL.Path
	originalMethod := c.Request.Method
	defer func() {
		c.Writer = originalWriter
		c.Request.Body = originalBody
		c.Request.ContentLength = originalContentLength
		c.Request.URL.Path = originalPath
		c.Request.Method = originalMethod
		common.CleanupBodyStorage(c)
	}()

	storage, err := common.CreateBodyStorage(relayBody)
	if err != nil {
		return http.StatusInternalServerError, []byte(err.Error())
	}
	c.Set(common.KeyBodyStorage, storage)
	c.Request.Body = io.NopCloser(storage)
	c.Request.ContentLength = int64(len(relayBody))
	c.Request.Method = http.MethodPost
	c.Request.URL.Path = "/v1/chat/completions"
	c.Request.Header.Set("Content-Type", "application/json")

	userCache, err := model.GetUserCache(carrier.UserId)
	if err != nil {
		return http.StatusInternalServerError, []byte(err.Error())
	}
	userCache.WriteContext(c)
	if forceAcceptUnsetRatioModel {
		userSetting := userCache.GetSetting()
		userSetting.AcceptUnsetRatioModel = true
		common.SetContextKey(c, constant.ContextKeyUserSetting, userSetting)
	}
	if strings.TrimSpace(usingGroup) == "" {
		usingGroup = userCache.Group
	}
	common.SetContextKey(c, constant.ContextKeyUsingGroup, usingGroup)
	if err := middleware.SetupContextForToken(c, carrier); err != nil {
		return http.StatusForbidden, []byte(err.Error())
	}
	common.SetContextKey(c, constant.ContextKeyUsingGroup, usingGroup)

	recorder := newPH01CaptureWriter()
	c.Writer = recorder
	middleware.Distribute()(c)
	if !c.IsAborted() {
		Relay(c, types.RelayFormatOpenAI)
	}
	return recorder.Status(), recorder.Body()
}

func ph01AllowedModelsForCarrier(userID int, carrier *model.Token) ([]string, string, error) {
	return ph01AllowedModelsForCarrierWithOptions(userID, carrier, false)
}

func ph01AllowedPublicStoryModelsForCarrier(userID int, carrier *model.Token) ([]string, string, error) {
	return ph01AllowedModelsForCarrierWithOptions(userID, carrier, true)
}

func ph01AllowedModelsForCarrierWithOptions(userID int, carrier *model.Token, explicitModelLimitsAuthoritative bool) ([]string, string, error) {
	userCache, err := model.GetUserCache(userID)
	if err != nil {
		return nil, "", err
	}
	if userCache.Status != common.UserStatusEnabled {
		return nil, "", errors.New("gateway user disabled")
	}

	usingGroup := strings.TrimSpace(carrier.Group)
	if usingGroup == "" {
		usingGroup = userCache.Group
	}
	if usingGroup != "auto" {
		if !service.GroupInUserUsableGroups(userCache.Group, usingGroup) {
			return nil, "", fmt.Errorf("group %s is not usable for user", usingGroup)
		}
		if !ratio_setting.ContainsGroupRatio(usingGroup) {
			return nil, "", fmt.Errorf("group %s is disabled", usingGroup)
		}
	}

	if explicitModelLimitsAuthoritative && carrier.ModelLimitsEnabled {
		models := ph01CleanModelLimits(carrier.GetModelLimits())
		if len(models) == 0 {
			return nil, usingGroup, errors.New("public story model limits are enabled but empty")
		}
		return models, usingGroup, nil
	}

	modelSet := map[string]struct{}{}
	if usingGroup == "auto" {
		for _, group := range service.GetUserAutoGroup(userCache.Group) {
			for _, modelName := range model.GetGroupEnabledModels(group) {
				modelSet[modelName] = struct{}{}
			}
		}
	} else {
		for _, modelName := range model.GetGroupEnabledModels(usingGroup) {
			modelSet[modelName] = struct{}{}
		}
	}

	if carrier.ModelLimitsEnabled {
		limits := carrier.GetModelLimitsMap()
		for modelName := range modelSet {
			if _, ok := limits[ratio_setting.FormatMatchingModelName(modelName)]; !ok {
				if _, exact := limits[modelName]; !exact {
					delete(modelSet, modelName)
				}
			}
		}
	}

	models := make([]string, 0, len(modelSet))
	for modelName := range modelSet {
		models = append(models, modelName)
	}
	models = ph01OrderAllowedModels(carrier, models)
	return models, usingGroup, nil
}

func ph01CleanModelLimits(limits []string) []string {
	models := make([]string, 0, len(limits))
	seen := map[string]struct{}{}
	for _, raw := range limits {
		modelName := strings.TrimSpace(raw)
		if modelName == "" {
			continue
		}
		if _, ok := seen[modelName]; ok {
			continue
		}
		seen[modelName] = struct{}{}
		models = append(models, modelName)
	}
	return models
}

func ph01OrderAllowedModels(carrier *model.Token, models []string) []string {
	sort.Strings(models)
	if !carrier.ModelLimitsEnabled {
		return models
	}

	remaining := make(map[string]struct{}, len(models))
	for _, modelName := range models {
		remaining[modelName] = struct{}{}
	}

	ordered := make([]string, 0, len(models))
	add := func(modelName string) {
		if _, ok := remaining[modelName]; !ok {
			return
		}
		ordered = append(ordered, modelName)
		delete(remaining, modelName)
	}

	for _, rawLimit := range carrier.GetModelLimits() {
		limit := strings.TrimSpace(rawLimit)
		if limit == "" {
			continue
		}
		formattedLimit := ratio_setting.FormatMatchingModelName(limit)
		for _, modelName := range models {
			if _, ok := remaining[modelName]; !ok {
				continue
			}
			formattedModelName := ratio_setting.FormatMatchingModelName(modelName)
			if modelName == limit ||
				formattedModelName == limit ||
				modelName == formattedLimit ||
				formattedModelName == formattedLimit {
				add(modelName)
			}
		}
	}

	for _, modelName := range models {
		add(modelName)
	}
	return ordered
}

func ph01BuildRelayBody(plaintext []byte) ([]byte, ph01ChatRequest, error) {
	var raw map[string]interface{}
	if err := json.Unmarshal(plaintext, &raw); err != nil {
		return nil, ph01ChatRequest{}, err
	}
	if extra, ok := raw["extra"].(map[string]interface{}); ok {
		delete(raw, "extra")
		for k, v := range extra {
			if _, exists := raw[k]; !exists {
				raw[k] = v
			}
		}
	}
	body, err := json.Marshal(raw)
	if err != nil {
		return nil, ph01ChatRequest{}, err
	}
	var chatReq ph01ChatRequest
	if err := json.Unmarshal(body, &chatReq); err != nil {
		return nil, ph01ChatRequest{}, err
	}
	chatReq.Model = strings.TrimSpace(chatReq.Model)
	if chatReq.Model == "" {
		return nil, ph01ChatRequest{}, errors.New("model required")
	}
	return body, chatReq, nil
}

func ph01ValidatePublicStoryChatRequest(chatReq ph01ChatRequest) error {
	if chatReq.Stream {
		return errors.New("public story chat does not support stream")
	}
	if len(chatReq.Tools) > 0 {
		return errors.New("public story chat does not support tools")
	}
	return nil
}

func ph01RequireRootPublicStoryCarrier(c *gin.Context, enforceClientIP bool) (*model.Token, string, []string, bool) {
	carrier, err := model.EnsurePH01RootPublicToken()
	if err != nil {
		ph01ProtocolError(c, http.StatusServiceUnavailable, ph01ErrInternalError, err.Error())
		return nil, "", nil, false
	}
	if !model.IsPH01PublicToken(carrier) {
		ph01ProtocolError(c, http.StatusServiceUnavailable, ph01ErrInvalidChannel, "PH01 public carrier key mismatch")
		return nil, "", nil, false
	}
	if enforceClientIP && !ph01CarrierAllowsClientIP(c, carrier) {
		ph01ProtocolError(c, http.StatusForbidden, ph01ErrAccessDenied, "client IP is not allowed")
		return nil, "", nil, false
	}
	if !carrier.UnlimitedQuota && carrier.RemainQuota <= 0 {
		ph01ProtocolError(c, http.StatusTooManyRequests, ph01ErrRateLimitExceeded, "")
		return nil, "", nil, false
	}
	allowedModels, usingGroup, err := ph01AllowedPublicStoryModelsForCarrier(carrier.UserId, carrier)
	if err != nil {
		ph01ProtocolError(c, http.StatusForbidden, ph01ErrModelNotAllowed, err.Error())
		return nil, "", nil, false
	}
	if len(allowedModels) == 0 {
		ph01ProtocolError(c, http.StatusForbidden, ph01ErrModelNotAllowed, fmt.Sprintf(
			"no public story model available (group=%s, model_limits_enabled=%t, configured_models=%d)",
			usingGroup,
			carrier.ModelLimitsEnabled,
			len(ph01CleanModelLimits(carrier.GetModelLimits())),
		))
		return nil, "", nil, false
	}
	return carrier, usingGroup, allowedModels, true
}

func ph01CarrierAllowsClientIP(c *gin.Context, carrier *model.Token) bool {
	allowIps := carrier.GetIpLimits()
	if len(allowIps) == 0 {
		return true
	}
	ip := net.ParseIP(c.ClientIP())
	if ip == nil {
		return false
	}
	return common.IsIpInCIDRList(ip, allowIps)
}

func ph01RequireChannel(c *gin.Context, id string) (*ph01Channel, bool) {
	id = strings.TrimSpace(id)
	if id == "" {
		ph01ProtocolError(c, http.StatusBadRequest, ph01ErrInvalidPayload, "channel_id required")
		return nil, false
	}
	ch, err := ph01GetChannel(id)
	if err != nil {
		ph01ProtocolError(c, http.StatusInternalServerError, ph01ErrInternalError, err.Error())
		return nil, false
	}
	if ch == nil {
		ph01ProtocolError(c, http.StatusUnauthorized, ph01ErrInvalidChannel, "")
		return nil, false
	}
	return ch, true
}

func ph01StoreChannel(ch *ph01Channel) error {
	if ch == nil || ch.ID == "" {
		return errors.New("invalid PH01 channel")
	}
	raw, err := json.Marshal(ch)
	if err != nil {
		return err
	}
	ttl := time.Until(ch.ExpiresAt)
	if ttl <= 0 {
		return errors.New("PH01 channel already expired")
	}
	if common.RedisEnabled && common.RDB != nil {
		return common.RedisSet(ph01ChannelPrefix+ch.ID, string(raw), ttl)
	}
	ph01Channels.Store(ch.ID, string(raw))
	return nil
}

func ph01GetChannel(id string) (*ph01Channel, error) {
	var raw string
	if common.RedisEnabled && common.RDB != nil {
		value, err := common.RedisGet(ph01ChannelPrefix + id)
		if err != nil {
			return nil, nil
		}
		raw = value
	} else {
		value, ok := ph01Channels.Load(id)
		if !ok {
			return nil, nil
		}
		raw, ok = value.(string)
		if !ok {
			ph01Channels.Delete(id)
			return nil, errors.New("PH01 channel store corrupted")
		}
	}
	var ch ph01Channel
	if err := json.Unmarshal([]byte(raw), &ch); err != nil {
		return nil, err
	}
	if ch.ExpiresAt.Before(time.Now()) {
		ph01DeleteChannel(ch.ID)
		return nil, nil
	}
	return &ch, nil
}

func ph01TouchChannel(ch *ph01Channel) error {
	if ch == nil || ch.ID == "" {
		return nil
	}
	ch.ExpiresAt = time.Now().Add(ph01ChannelIdleTTL)
	return ph01StoreChannel(ch)
}

func ph01DeleteChannel(id string) {
	if common.RedisEnabled && common.RDB != nil {
		_ = common.RedisDel(ph01ChannelPrefix + id)
		return
	}
	ph01Channels.Delete(id)
}

func ph01RevokeChannelsForUser(ph01UserID uint64) (int, error) {
	if ph01UserID == 0 {
		return 0, errors.New("ph01 user id is empty")
	}
	if common.RedisEnabled && common.RDB != nil {
		return ph01RevokeRedisChannelsForUser(ph01UserID)
	}
	revoked := 0
	ph01Channels.Range(func(key, value any) bool {
		raw, ok := value.(string)
		if !ok {
			ph01Channels.Delete(key)
			return true
		}
		var ch ph01Channel
		if err := json.Unmarshal([]byte(raw), &ch); err != nil {
			ph01Channels.Delete(key)
			return true
		}
		if ch.PH01UserID == ph01UserID {
			ph01Channels.Delete(key)
			revoked++
		}
		return true
	})
	return revoked, nil
}

func ph01RevokeRedisChannelsForUser(ph01UserID uint64) (int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var cursor uint64
	revoked := 0
	for {
		keys, next, err := common.RDB.Scan(ctx, cursor, ph01ChannelPrefix+"*", 100).Result()
		if err != nil {
			return revoked, err
		}
		for _, key := range keys {
			raw, err := common.RDB.Get(ctx, key).Result()
			if err != nil {
				continue
			}
			var ch ph01Channel
			if err := json.Unmarshal([]byte(raw), &ch); err != nil {
				_ = common.RDB.Del(ctx, key).Err()
				continue
			}
			if ch.PH01UserID == ph01UserID {
				if err := common.RDB.Del(ctx, key).Err(); err != nil {
					return revoked, err
				}
				revoked++
			}
		}
		if next == 0 {
			break
		}
		cursor = next
	}
	return revoked, nil
}

func ph01ModelAllowed(models []string, requested string) bool {
	requested = strings.TrimSpace(requested)
	for _, modelName := range models {
		if modelName == requested {
			return true
		}
	}
	return false
}

func ph01ParseEncryptedEnvelope(rawBody []byte) (ph01EncryptedEnvelope, bool) {
	var env ph01EncryptedEnvelope
	if len(bytes.TrimSpace(rawBody)) == 0 {
		return env, false
	}
	if err := common.Unmarshal(rawBody, &env); err != nil {
		return env, false
	}
	env.ChannelID = strings.TrimSpace(env.ChannelID)
	env.Nonce = strings.TrimSpace(env.Nonce)
	env.Ciphertext = strings.TrimSpace(env.Ciphertext)
	env.Tag = strings.TrimSpace(env.Tag)
	if env.ChannelID == "" || env.Nonce == "" || env.Ciphertext == "" || env.Tag == "" {
		return env, false
	}
	return env, true
}

func ph01ProtocolError(c *gin.Context, status int, code string, message string) {
	logger.LogWarnFields(c.Request.Context(), "ph01_protocol_error", map[string]any{
		"layer":       "gateway_handler",
		"operation":   "ph01_protocol",
		"phase":       "error_response",
		"status":      "failure",
		"status_code": status,
		"error_code":  code,
		"message":     ph01LogPreview(message, 1200),
		"method":      c.Request.Method,
		"path":        c.Request.URL.Path,
	})
	c.JSON(status, gin.H{
		"error":   code,
		"message": message,
	})
}

func ph01PublicStoryMode(encrypted bool) string {
	if encrypted {
		return "encrypted"
	}
	return "plaintext"
}

func ph01PublicStoryMessageStats(messages []map[string]interface{}) (int, int) {
	chars := 0
	for _, message := range messages {
		chars += ph01ContentChars(message["content"])
	}
	return len(messages), chars
}

func ph01ContentChars(value interface{}) int {
	switch typed := value.(type) {
	case string:
		return len([]rune(typed))
	case []interface{}:
		total := 0
		for _, item := range typed {
			total += ph01ContentChars(item)
		}
		return total
	case map[string]interface{}:
		if text, ok := typed["text"]; ok {
			return ph01ContentChars(text)
		}
		if content, ok := typed["content"]; ok {
			return ph01ContentChars(content)
		}
		return 0
	default:
		if value == nil {
			return 0
		}
		return len([]rune(fmt.Sprint(value)))
	}
}

func ph01LogPreview(value string, maxRunes int) string {
	value = strings.TrimSpace(value)
	if maxRunes <= 0 {
		return ""
	}
	runes := []rune(value)
	if len(runes) <= maxRunes {
		return value
	}
	return string(runes[:maxRunes]) + "...(truncated)"
}

func ph01ParsePubkey(pubkeyHex string) (*secp256k1.PublicKey, error) {
	raw, err := hex.DecodeString(strings.TrimSpace(pubkeyHex))
	if err != nil {
		return nil, err
	}
	return secp256k1.ParsePubKey(raw)
}

func ph01DeriveSharedKey(localPriv *secp256k1.PrivateKey, remotePub *secp256k1.PublicKey) ([]byte, error) {
	var pubJ secp256k1.JacobianPoint
	remotePub.AsJacobian(&pubJ)
	var resJ secp256k1.JacobianPoint
	secp256k1.ScalarMultNonConst(&localPriv.Key, &pubJ, &resJ)
	resJ.ToAffine()
	shared := resJ.X.Bytes()
	reader := hkdf.New(sha256.New, shared[:], []byte("hanako-aes-v1"), nil)
	aesKey := make([]byte, 32)
	if _, err := io.ReadFull(reader, aesKey); err != nil {
		return nil, err
	}
	return aesKey, nil
}

func ph01EncryptGCM(aesKey []byte, plaintext []byte) (string, string, string, error) {
	block, err := aes.NewCipher(aesKey)
	if err != nil {
		return "", "", "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", "", "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", "", "", err
	}
	combined := gcm.Seal(nil, nonce, plaintext, nil)
	if len(combined) < gcm.Overhead() {
		return "", "", "", errors.New("gcm output too short")
	}
	ct := combined[:len(combined)-gcm.Overhead()]
	tag := combined[len(combined)-gcm.Overhead():]
	return hex.EncodeToString(nonce), hex.EncodeToString(ct), hex.EncodeToString(tag), nil
}

func ph01DecryptGCM(aesKey []byte, nonceHex string, ciphertextHex string, tagHex string) ([]byte, error) {
	block, err := aes.NewCipher(aesKey)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce, err := hex.DecodeString(nonceHex)
	if err != nil {
		return nil, err
	}
	ct, err := hex.DecodeString(ciphertextHex)
	if err != nil {
		return nil, err
	}
	tag, err := hex.DecodeString(tagHex)
	if err != nil {
		return nil, err
	}
	if len(nonce) != gcm.NonceSize() {
		return nil, fmt.Errorf("nonce length: %d", len(nonce))
	}
	if len(tag) != gcm.Overhead() {
		return nil, fmt.Errorf("tag length: %d", len(tag))
	}
	combined := append(ct, tag...)
	return gcm.Open(nil, nonce, combined, nil)
}

func ph01WriteEncryptedSSE(c *gin.Context, channelID string, aesKey []byte, relayBody []byte) {
	c.Header("Content-Type", "text/event-stream")
	c.Header("Cache-Control", "no-cache")
	c.Header("Connection", "keep-alive")
	c.Header("X-Accel-Buffering", "no")
	flusher, _ := c.Writer.(http.Flusher)

	scanner := bufio.NewScanner(bytes.NewReader(relayBody))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "" {
			continue
		}
		if strings.TrimSpace(line) == "data: [DONE]" {
			fmt.Fprint(c.Writer, "data: [DONE]\n\n")
			if flusher != nil {
				flusher.Flush()
			}
			continue
		}
		nonceHex, ctHex, tagHex, err := ph01EncryptGCM(aesKey, []byte(line))
		if err != nil {
			break
		}
		raw, _ := json.Marshal(ph01EncryptedEnvelope{
			ChannelID:  channelID,
			Nonce:      nonceHex,
			Ciphertext: ctHex,
			Tag:        tagHex,
		})
		fmt.Fprintf(c.Writer, "data: %s\n\n", raw)
		if flusher != nil {
			flusher.Flush()
		}
	}
	fmt.Fprint(c.Writer, "data: [DONE]\n\n")
	if flusher != nil {
		flusher.Flush()
	}
}

type ph01CaptureWriter struct {
	header http.Header
	body   bytes.Buffer
	status int
	size   int
}

func newPH01CaptureWriter() *ph01CaptureWriter {
	return &ph01CaptureWriter{
		header: http.Header{},
		status: http.StatusOK,
		size:   -1,
	}
}

func (w *ph01CaptureWriter) Header() http.Header {
	return w.header
}

func (w *ph01CaptureWriter) WriteHeader(statusCode int) {
	if w.Written() {
		return
	}
	w.status = statusCode
	w.size = 0
}

func (w *ph01CaptureWriter) Write(data []byte) (int, error) {
	if !w.Written() {
		w.WriteHeader(http.StatusOK)
	}
	n, err := w.body.Write(data)
	w.size += n
	return n, err
}

func (w *ph01CaptureWriter) WriteString(s string) (int, error) {
	return w.Write([]byte(s))
}

func (w *ph01CaptureWriter) Status() int {
	return w.status
}

func (w *ph01CaptureWriter) Size() int {
	return w.size
}

func (w *ph01CaptureWriter) Written() bool {
	return w.size >= 0
}

func (w *ph01CaptureWriter) WriteHeaderNow() {
	if !w.Written() {
		w.WriteHeader(w.status)
	}
}

func (w *ph01CaptureWriter) WriteHeaderNowWithStatus(statusCode int) {
	w.WriteHeader(statusCode)
}

func (w *ph01CaptureWriter) Flush() {}

func (w *ph01CaptureWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return nil, nil, errors.New("hijack is not supported by PH01 capture writer")
}

func (w *ph01CaptureWriter) CloseNotify() <-chan bool {
	ch := make(chan bool, 1)
	return ch
}

func (w *ph01CaptureWriter) Pusher() http.Pusher {
	return nil
}

func (w *ph01CaptureWriter) Body() []byte {
	return w.body.Bytes()
}
