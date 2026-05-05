// p2p-authority 持有 P2P 网络治理 Root 私钥，签发否决块等特权对象。
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
	"github.com/hanako/legacy-p2p-authority/internal/authority"
	"github.com/hanako/legacy-p2p-authority/internal/config"
	"github.com/hanako/legacy-p2p-authority/internal/rootkey"
)

func main() {
	configPath := flag.String("config", "config.hcl", "HCL config file path")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	serverCfg := cfg.Servers["p2p_authority"]
	if serverCfg == nil {
		log.Fatal("server 'p2p_authority' not found in config")
	}
	if serverCfg.AdminToken == "" {
		log.Fatal("server.admin_token is required")
	}

	root, err := rootkey.Load(cfg.RootKey.KeyID, cfg.RootKey.PrivateKeyHex)
	if err != nil {
		log.Fatalf("load root key: %v", err)
	}

	r := gin.Default()
	corsOrigins := serverCfg.CORSOrigins
	if len(corsOrigins) == 0 {
		corsOrigins = []string{"*"}
	}
	r.Use(cors.New(cors.Config{
		AllowOrigins: corsOrigins,
		AllowMethods: []string{"GET", "POST", "OPTIONS"},
		AllowHeaders: []string{"Origin", "Content-Type", "Authorization"},
		MaxAge:       12 * time.Hour,
	}))

	(&authority.Handler{
		Root:       root,
		AdminToken: serverCfg.AdminToken,
	}).Register(r)

	srv := &http.Server{
		Addr:    serverCfg.Listen,
		Handler: r,
	}
	go func() {
		log.Printf("[info] p2p-authority listening on %s root_key=%s", serverCfg.Listen, root.KeyID)
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
