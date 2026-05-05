// legacy-ai-gateway 是旧 Go 版 AI 网关原型主入口。
//
// 当前生产 AI 网关是 ph01-ai-gateway（魔改 New API），本入口不参与正式部署。
//
// 启动配置：从 HCL 配置文件读取（默认 config.hcl）。
//
//	./ai-gateway -config=/path/to/config.hcl
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-contrib/cors"
	"github.com/gin-gonic/gin"
	"github.com/hanako/ph01-backend/internal/adminai"
	"github.com/hanako/ph01-backend/internal/config"
	"github.com/hanako/ph01-backend/internal/db"
	"github.com/hanako/ph01-backend/internal/gateway"
	"github.com/hanako/ph01-backend/internal/llm"
	"github.com/hanako/ph01-backend/internal/redisx"
	"github.com/hanako/ph01-backend/web"
)

func main() {
	configPath := flag.String("config", "config.hcl", "HCL config file path")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	dbCfg := cfg.Databases["ai"]
	if dbCfg == nil {
		log.Fatal("database 'ai' not found in config")
	}
	redisCfg := cfg.Redis["ai"]
	if redisCfg == nil {
		log.Fatal("redis 'ai' not found in config")
	}
	serverCfg := cfg.Servers["ai_gateway"]
	if serverCfg == nil {
		log.Fatal("server 'ai_gateway' not found in config")
	}

	gormDB, err := db.Open(dbCfg.Driver, dbCfg.DSN)
	if err != nil {
		log.Fatalf("db open: %v", err)
	}
	if err := llm.AutoMigrate(gormDB); err != nil {
		log.Fatalf("auto migrate: %v", err)
	}

	rdb, err := redisx.Open(redisCfg.URL)
	if err != nil {
		log.Fatalf("redis open: %v", err)
	}

	repo := llm.NewRepo(gormDB)
	if err := repo.Seed(); err != nil {
		log.Fatalf("seed tiers: %v", err)
	}

	authClient := gateway.NewAuthClient(serverCfg.AuthBase)
	channelStore := gateway.NewChannelStore(rdb)
	upstreamPipe := gateway.NewUpstreamPipe()

	gatewayHandler := &gateway.Handler{
		Auth:         authClient,
		Channels:     channelStore,
		LLM:          repo,
		UpstreamPipe: upstreamPipe,
	}
	adminHandler := &adminai.Handler{
		LLM:        repo,
		AdminToken: serverCfg.AdminToken,
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
		c.JSON(http.StatusOK, gin.H{"ok": true, "service": "ai-gateway"})
	})

	v1 := r.Group("/api/v1")
	gatewayHandler.Register(v1)

	adminGroup := r.Group("/admin")
	adminHandler.Register(adminGroup)

	r.StaticFS("/admin-ui", web.AdminFS())

	srv := &http.Server{
		Addr:    serverCfg.Listen,
		Handler: r,
	}
	go func() {
		log.Printf("[info] ai-gateway listening on %s", serverCfg.Listen)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	log.Println("[info] shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}
