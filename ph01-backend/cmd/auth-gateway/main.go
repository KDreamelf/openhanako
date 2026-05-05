// auth-gateway 主入口。
//
// 启动配置：从 HCL 配置文件读取（默认 config.hcl）。
//
//	./auth-gateway -config=/path/to/config.hcl
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-contrib/cors"
	"github.com/gin-gonic/gin"
	"github.com/hanako/ph01-backend/internal/admin"
	"github.com/hanako/ph01-backend/internal/auth"
	"github.com/hanako/ph01-backend/internal/config"
	hcrypto "github.com/hanako/ph01-backend/internal/crypto"
	"github.com/hanako/ph01-backend/internal/db"
	"github.com/hanako/ph01-backend/internal/redisx"
	"github.com/hanako/ph01-backend/internal/syncai"
	"github.com/hanako/ph01-backend/internal/system"
	"github.com/hanako/ph01-backend/internal/user"
	"github.com/hanako/ph01-backend/web"
	"github.com/redis/go-redis/v9"
)

func main() {
	configPath := flag.String("config", "config.hcl", "HCL config file path")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	dbCfg := cfg.Databases["auth"]
	if dbCfg == nil {
		log.Fatal("database 'auth' not found in config")
	}
	redisCfg := cfg.Redis["auth"]
	serverCfg := cfg.Servers["auth_gateway"]
	if serverCfg == nil {
		log.Fatal("server 'auth_gateway' not found in config")
	}

	gormDB, err := db.Open(dbCfg.Driver, dbCfg.DSN)
	if err != nil {
		log.Fatalf("db open: %v", err)
	}
	if err := user.AutoMigrate(gormDB); err != nil {
		log.Fatalf("auto migrate: %v", err)
	}
	if err := system.AutoMigrate(gormDB); err != nil {
		log.Fatalf("system auto migrate: %v", err)
	}

	userStore := user.NewStore(gormDB)
	systemStore := system.NewStore(gormDB, *configPath)
	if err := userStore.EnsureBootstrapRootRole(); err != nil {
		log.Fatalf("ensure root role: %v", err)
	}

	var rdb *redis.Client
	if redisCfg != nil && redisCfg.URL != "" {
		rdb, err = redisx.Open(redisCfg.URL)
		if err != nil {
			log.Printf("[warn] redis unavailable: %v (nonce replay protection disabled)", err)
		} else {
			log.Printf("[info] redis connected at %s", redisCfg.URL)
		}
	}

	verifier := hcrypto.NewSignedRequestVerifier(rdb, "nonce:auth")
	var rfaService *auth.RFAService
	var registrationEmail *auth.RegistrationEmailService
	var recoveryLimiter auth.RecoveryLimiter
	if rdb != nil {
		recoveryLimiter = redisx.NewRecoveryLimiter(rdb)
		rfaService = auth.NewRFAService(userStore, auth.NewRedisRFAStore(rdb), system.NewDynamicSMTPSender(systemStore))
		registrationEmail = auth.NewRegistrationEmailService(
			userStore,
			auth.NewRedisRFAStoreWithPrefix(rdb, "register_email"),
			system.NewDynamicSMTPSender(systemStore),
		)
		log.Printf("[info] registration and recovery email verification enabled with dynamic SMTP settings")
	} else {
		log.Printf("[warn] recovery limiter and email verification disabled: redis unavailable")
	}
	var gatewaySyncer auth.GatewayUserSyncer
	if syncCfg := cfg.AIGatewaySync["default"]; syncCfg != nil && syncCfg.Enabled {
		gatewaySyncer = syncai.NewClient(syncCfg.BaseURL, syncCfg.InternalToken, time.Duration(syncCfg.TimeoutMS)*time.Millisecond)
		log.Printf("[info] ai gateway user sync enabled: %s", syncCfg.BaseURL)
	}
	authHandler := &auth.Handler{
		UserStore:         userStore,
		Verifier:          verifier,
		RecoveryLimiter:   recoveryLimiter,
		RFA:               rfaService,
		RegistrationEmail: registrationEmail,
		GatewaySyncer:     gatewaySyncer,
	}
	adminHandler := &admin.Handler{
		UserStore:   userStore,
		SystemStore: systemStore,
		Verifier:    verifier,
		AdminToken:  serverCfg.AdminToken,
	}

	r := gin.Default()
	corsOrigins := serverCfg.CORSOrigins
	if len(corsOrigins) == 0 {
		corsOrigins = []string{"*"}
	}
	r.Use(cors.New(cors.Config{
		AllowOrigins: corsOrigins,
		AllowMethods: []string{"GET", "POST", "PATCH", "DELETE", "OPTIONS"},
		AllowHeaders: []string{"Origin", "Content-Type", "Authorization"},
		MaxAge:       12 * time.Hour,
	}))

	r.GET("/healthz", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"ok": true, "service": "auth-gateway"})
	})

	v1 := r.Group("/api/v1")
	authHandler.Register(v1)

	adminGroup := r.Group("/admin")
	adminHandler.Register(adminGroup)

	r.StaticFS("/admin-ui", web.AdminFS())

	srv := &http.Server{
		Addr:    serverCfg.Listen,
		Handler: r,
	}

	servers := []*http.Server{srv}
	errCh := make(chan error, 2)
	startHTTPServer("auth-gateway", srv, errCh)

	if mtlsCfg := cfg.Servers["auth_gateway_mtls"]; mtlsCfg != nil && mtlsCfg.Listen != "" {
		tlsCfg, err := buildTLSConfig(mtlsCfg)
		if err != nil {
			log.Fatalf("build auth_gateway_mtls tls config: %v", err)
		}
		mtlsSrv := &http.Server{
			Addr:      mtlsCfg.Listen,
			Handler:   r,
			TLSConfig: tlsCfg,
		}
		servers = append(servers, mtlsSrv)
		startTLSServer("auth-gateway-mtls", mtlsSrv, errCh)
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	select {
	case <-stop:
	case err := <-errCh:
		log.Fatalf("listen: %v", err)
	}
	log.Println("[info] shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, server := range servers {
		_ = server.Shutdown(ctx)
	}
}

func startHTTPServer(name string, srv *http.Server, errCh chan<- error) {
	go func() {
		log.Printf("[info] %s listening on %s", name, srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- fmt.Errorf("%s: %w", name, err)
		}
	}()
}

func startTLSServer(name string, srv *http.Server, errCh chan<- error) {
	go func() {
		log.Printf("[info] %s listening on %s", name, srv.Addr)
		if err := srv.ListenAndServeTLS("", ""); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- fmt.Errorf("%s: %w", name, err)
		}
	}()
}

func buildTLSConfig(serverCfg *config.Server) (*tls.Config, error) {
	if serverCfg.TLS == nil || !serverCfg.TLS.Enabled {
		return nil, fmt.Errorf("tls block is missing or disabled")
	}
	if serverCfg.TLS.CertFile == "" || serverCfg.TLS.KeyFile == "" {
		return nil, fmt.Errorf("tls cert_file and key_file are required")
	}
	cert, err := tls.LoadX509KeyPair(serverCfg.TLS.CertFile, serverCfg.TLS.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("load server certificate: %w", err)
	}
	tlsCfg := &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{cert},
	}
	if serverCfg.TLS.RequireClientCert {
		if serverCfg.TLS.ClientCAFile == "" {
			return nil, fmt.Errorf("tls client_ca_file is required when require_client_cert is true")
		}
		caPEM, err := os.ReadFile(serverCfg.TLS.ClientCAFile)
		if err != nil {
			return nil, fmt.Errorf("read client ca file: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(caPEM) {
			return nil, fmt.Errorf("client ca file contains no PEM certificates")
		}
		tlsCfg.ClientCAs = pool
		tlsCfg.ClientAuth = tls.RequireAndVerifyClientCert
	}
	return tlsCfg, nil
}
