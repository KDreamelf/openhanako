package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"ph01-experience-hub/internal/governance"
	"ph01-experience-hub/internal/hub"
)

func main() {
	configPath := flag.String("config", "config.json", "JSON config file path")
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	if cfg.Listen == "" {
		cfg.Listen = ":8090"
	}
	if cfg.StorageRoot == "" {
		cfg.StorageRoot = "./data/experience-hub"
	}
	store := hub.NewStore(cfg.StorageRoot)
	if err := store.Init(); err != nil {
		log.Fatalf("init store: %v", err)
	}

	var governanceService *governance.Service
	if cfg.Governance.Enabled {
		governanceService, err = governance.Load(cfg.Governance)
		if err != nil {
			log.Fatalf("init governance: %v", err)
		}
		log.Printf("[info] governance enabled with master certificate %s", cfg.Governance.MasterCertificatePath)
	}

	handler := &hub.Handler{
		Store:          store,
		Governance:     governanceService,
		AuthCenter:     cfg.AuthCenter,
		Review:         cfg.Review,
		DelegatedPow:   hub.HTTPDelegatedPowClient{},
		AdminToken:     cfg.AdminToken,
		CORSOrigins:    cfg.CORSOrigins,
		MaxUploadBytes: cfg.MaxUploadBytes,
	}
	runCtx, runCancel := context.WithCancel(context.Background())
	defer runCancel()
	if cfg.ReviewChain.Enabled {
		scheduler := &hub.ReviewChainScheduler{
			Store:      store,
			Governance: governanceService,
			Config:     cfg.ReviewChain,
		}
		go scheduler.Run(runCtx)
	}
	srv := &http.Server{
		Addr:    cfg.Listen,
		Handler: handler,
	}

	go func() {
		log.Printf("[info] experience-network-manager listening on %s storage=%s", cfg.Listen, cfg.StorageRoot)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	log.Println("[info] shutting down...")
	runCancel()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}

func loadConfig(path string) (*hub.Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg hub.Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	if cfg.AdminToken == "" {
		cfg.AdminToken = os.Getenv("PH01_EXPERIENCE_HUB_TOKEN")
	}
	if cfg.AuthCenter.BaseURL == "" {
		cfg.AuthCenter.BaseURL = os.Getenv("PH01_AUTH_CENTER_BASE_URL")
	}
	return &cfg, nil
}
