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
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"experience-dht/internal/dht"
	"gopkg.in/yaml.v3"
)

const (
	defaultStatePath   = "./data/experience-dht/state.json"
	containerStateDir  = "/data/experience-dht"
	containerStateFile = "state.json"
	defaultListenAddr  = ":8091"
	defaultUDPAddr     = ":41001"
	defaultQUICAddr    = ":41002"
)

func main() {
	configPath := flag.String("config", "config.yml", "YAML config file path")
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	if cfg.Listen == "" {
		cfg.Listen = defaultListenAddr
	}
	if cfg.UDPListen == "" {
		cfg.UDPListen = defaultUDPAddr
	}
	if cfg.QUICListen == "" {
		cfg.QUICListen = defaultQUICAddr
	}
	cfg.StatePath = resolveStatePath(containerStateDir)
	store := dht.NewStateStore(cfg.StatePath)
	if err := store.Init(cfg.NodeID); err != nil {
		log.Fatalf("init state: %v", err)
	}
	state, err := store.Get()
	if err != nil {
		log.Fatalf("read state: %v", err)
	}
	cfg.NodeID = state.NodeID
	handler := dht.NewHandler(*cfg, store, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go handler.RunHeartbeat(ctx)
	go handler.RunPeerBootstrap(ctx)
	go func() {
		if err := handler.RunUDPServer(ctx, cfg.UDPListen); err != nil && ctx.Err() == nil {
			log.Printf("[warn] UDP listener disabled: %v", err)
		}
	}()
	go func() {
		if err := handler.RunQUICServer(ctx, cfg.QUICListen); err != nil && ctx.Err() == nil {
			log.Printf("[warn] QUIC listener disabled: %v", err)
		}
	}()

	srv := &http.Server{
		Addr:    cfg.Listen,
		Handler: handler,
	}
	go func() {
		log.Printf("[info] experience-dht listening on %s node=%s", cfg.Listen, cfg.NodeID)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	cancel()
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	_ = srv.Shutdown(shutdownCtx)
}

func loadConfig(path string) (*dht.Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			cfg := dht.Config{}
			applyEnvConfig(&cfg)
			if strings.TrimSpace(cfg.InitPassword) == "" {
				return nil, errors.New("config file not found and EXPERIENCE_DHT_INIT_PASSWORD is empty")
			}
			return &cfg, nil
		}
		return nil, err
	}
	var cfg dht.Config
	switch strings.ToLower(filepath.Ext(path)) {
	case ".json":
		if err := json.Unmarshal(data, &cfg); err != nil {
			return nil, err
		}
	default:
		if err := yaml.Unmarshal(data, &cfg); err != nil {
			return nil, err
		}
	}
	applyEnvConfig(&cfg)
	return &cfg, nil
}

func applyEnvConfig(cfg *dht.Config) {
	if strings.TrimSpace(cfg.Listen) == "" {
		cfg.Listen = strings.TrimSpace(os.Getenv("EXPERIENCE_DHT_LISTEN"))
	}
	if strings.TrimSpace(cfg.UDPListen) == "" {
		cfg.UDPListen = strings.TrimSpace(os.Getenv("EXPERIENCE_DHT_UDP_LISTEN"))
	}
	if strings.TrimSpace(cfg.QUICListen) == "" {
		cfg.QUICListen = strings.TrimSpace(os.Getenv("EXPERIENCE_DHT_QUIC_LISTEN"))
	}
	if strings.TrimSpace(cfg.InitPassword) == "" {
		cfg.InitPassword = os.Getenv("EXPERIENCE_DHT_INIT_PASSWORD")
	}
}

func resolveStatePath(containerDir string) string {
	if info, err := os.Stat(containerDir); err == nil && info.IsDir() {
		return filepath.Join(containerDir, containerStateFile)
	}
	return defaultStatePath
}
