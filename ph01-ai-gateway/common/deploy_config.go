package common

import (
	"os"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

type DeploymentConfig struct {
	Server    DeploymentServerConfig    `yaml:"server"`
	Database  DeploymentDatabaseConfig  `yaml:"database"`
	Redis     DeploymentRedisConfig     `yaml:"redis"`
	Security  DeploymentSecurityConfig  `yaml:"security"`
	Runtime   DeploymentRuntimeConfig   `yaml:"runtime"`
	PH01Auth  DeploymentPH01AuthConfig  `yaml:"ph01_auth"`
	Analytics DeploymentAnalyticsConfig `yaml:"analytics"`
}

type DeploymentServerConfig struct {
	Port                 int     `yaml:"port"`
	LogDir               string  `yaml:"log_dir"`
	NodeName             string  `yaml:"node_name"`
	GinMode              string  `yaml:"gin_mode"`
	FrontendBaseURL      string  `yaml:"frontend_base_url"`
	GatewayPublicBaseURL string  `yaml:"gateway_public_base_url"`
	SystemName           *string `yaml:"system_name"`
	FrontendTheme        *string `yaml:"frontend_theme"`
	HomePageContent      *string `yaml:"home_page_content"`
	Logo                 *string `yaml:"logo"`
	Footer               *string `yaml:"footer"`
}

type DeploymentDatabaseConfig struct {
	SQLDSN       string `yaml:"sql_dsn"`
	LogSQLDSN    string `yaml:"log_sql_dsn"`
	SQLitePath   string `yaml:"sqlite_path"`
	MaxIdleConns int    `yaml:"max_idle_conns"`
	MaxOpenConns int    `yaml:"max_open_conns"`
	MaxLifetime  int    `yaml:"max_lifetime_seconds"`
}

type DeploymentRedisConfig struct {
	ConnString    string `yaml:"conn_string"`
	PoolSize      int    `yaml:"pool_size"`
	SyncFrequency int    `yaml:"sync_frequency_seconds"`
}

type DeploymentSecurityConfig struct {
	SessionSecret          string   `yaml:"session_secret"`
	CryptoSecret           string   `yaml:"crypto_secret"`
	TLSInsecureSkipVerify  *bool    `yaml:"tls_insecure_skip_verify"`
	TrustedRedirectDomains []string `yaml:"trusted_redirect_domains"`
	TrustProxyHeaders      *bool    `yaml:"trust_proxy_headers"`
}

type DeploymentRuntimeConfig struct {
	DebugEnabled           *bool  `yaml:"debug_enabled"`
	MemoryCacheEnabled     *bool  `yaml:"memory_cache_enabled"`
	ErrorLogEnabled        *bool  `yaml:"error_log_enabled"`
	BatchUpdateEnabled     *bool  `yaml:"batch_update_enabled"`
	BatchUpdateInterval    int    `yaml:"batch_update_interval_seconds"`
	ChannelUpdateFrequency int    `yaml:"channel_update_frequency_seconds"`
	GenerateDefaultToken   *bool  `yaml:"generate_default_token"`
	UpdateTask             *bool  `yaml:"update_task"`
	StreamingTimeout       int    `yaml:"streaming_timeout_seconds"`
	StreamScannerMaxBuffer int    `yaml:"stream_scanner_max_buffer_mb"`
	MaxRequestBodyMB       int    `yaml:"max_request_body_mb"`
	AzureDefaultAPIVersion string `yaml:"azure_default_api_version"`
}

type DeploymentPH01AuthConfig struct {
	BaseURL           string `yaml:"base_url"`
	InternalToken     string `yaml:"internal_token"`
	CACert            string `yaml:"ca_cert"`
	ClientCert        string `yaml:"client_cert"`
	ClientKey         string `yaml:"client_key"`
	ServerName        string `yaml:"server_name"`
	GeoIPAPIURL       string `yaml:"geoip_api_url"`
	GeoIPAPITimeoutMS int    `yaml:"geoip_api_timeout_ms"`
	GeoIPCacheTTLHour int    `yaml:"geoip_cache_ttl_hours"`
	GeoIPDBPath       string `yaml:"geoip_db_path"`
}

type DeploymentAnalyticsConfig struct {
	GoogleAnalyticsID string `yaml:"google_analytics_id"`
	UmamiWebsiteID    string `yaml:"umami_website_id"`
	UmamiScriptURL    string `yaml:"umami_script_url"`
}

func ApplyDeploymentConfig(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var cfg DeploymentConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return err
	}

	if cfg.Server.Port > 0 {
		*Port = cfg.Server.Port
		setEnvString("PORT", intString(cfg.Server.Port))
	}
	if cfg.Server.LogDir != "" {
		*LogDir = cfg.Server.LogDir
	}
	setEnvString("NODE_NAME", cfg.Server.NodeName)
	setEnvString("GIN_MODE", cfg.Server.GinMode)
	setEnvString("FRONTEND_BASE_URL", cfg.Server.FrontendBaseURL)
	setEnvString("PH01_GATEWAY_PUBLIC_BASE_URL", cfg.Server.GatewayPublicBaseURL)
	setEnvStringPtr("PH01_SYSTEM_NAME", cfg.Server.SystemName)
	setEnvStringPtr("PH01_FRONTEND_THEME", cfg.Server.FrontendTheme)
	setEnvRawStringPtr("PH01_HOME_PAGE_CONTENT", cfg.Server.HomePageContent)
	setEnvStringPtr("PH01_LOGO", cfg.Server.Logo)
	setEnvRawStringPtr("PH01_FOOTER", cfg.Server.Footer)

	setEnvString("SQL_DSN", cfg.Database.SQLDSN)
	setEnvString("LOG_SQL_DSN", cfg.Database.LogSQLDSN)
	setEnvString("SQLITE_PATH", cfg.Database.SQLitePath)
	setEnvInt("SQL_MAX_IDLE_CONNS", cfg.Database.MaxIdleConns)
	setEnvInt("SQL_MAX_OPEN_CONNS", cfg.Database.MaxOpenConns)
	setEnvInt("SQL_MAX_LIFETIME", cfg.Database.MaxLifetime)

	setEnvString("REDIS_CONN_STRING", cfg.Redis.ConnString)
	setEnvInt("REDIS_POOL_SIZE", cfg.Redis.PoolSize)
	setEnvInt("SYNC_FREQUENCY", cfg.Redis.SyncFrequency)

	setEnvString("SESSION_SECRET", cfg.Security.SessionSecret)
	setEnvString("CRYPTO_SECRET", cfg.Security.CryptoSecret)
	setEnvBool("TLS_INSECURE_SKIP_VERIFY", cfg.Security.TLSInsecureSkipVerify)
	setEnvList("TRUSTED_REDIRECT_DOMAINS", cfg.Security.TrustedRedirectDomains)
	setEnvBool("PH01_TRUST_PROXY_HEADERS", cfg.Security.TrustProxyHeaders)

	setEnvBool("DEBUG", cfg.Runtime.DebugEnabled)
	setEnvBool("MEMORY_CACHE_ENABLED", cfg.Runtime.MemoryCacheEnabled)
	setEnvBool("ERROR_LOG_ENABLED", cfg.Runtime.ErrorLogEnabled)
	setEnvBool("BATCH_UPDATE_ENABLED", cfg.Runtime.BatchUpdateEnabled)
	setEnvInt("BATCH_UPDATE_INTERVAL", cfg.Runtime.BatchUpdateInterval)
	setEnvInt("CHANNEL_UPDATE_FREQUENCY", cfg.Runtime.ChannelUpdateFrequency)
	setEnvBool("GENERATE_DEFAULT_TOKEN", cfg.Runtime.GenerateDefaultToken)
	setEnvBool("UPDATE_TASK", cfg.Runtime.UpdateTask)
	setEnvInt("STREAMING_TIMEOUT", cfg.Runtime.StreamingTimeout)
	setEnvInt("STREAM_SCANNER_MAX_BUFFER_MB", cfg.Runtime.StreamScannerMaxBuffer)
	setEnvInt("MAX_REQUEST_BODY_MB", cfg.Runtime.MaxRequestBodyMB)
	setEnvString("AZURE_DEFAULT_API_VERSION", cfg.Runtime.AzureDefaultAPIVersion)

	setEnvString("PH01_AUTH_BASE_URL", cfg.PH01Auth.BaseURL)
	setEnvString("PH01_AUTH_INTERNAL_TOKEN", cfg.PH01Auth.InternalToken)
	setEnvString("PH01_AUTH_CA_CERT", cfg.PH01Auth.CACert)
	setEnvString("PH01_AUTH_CLIENT_CERT", cfg.PH01Auth.ClientCert)
	setEnvString("PH01_AUTH_CLIENT_KEY", cfg.PH01Auth.ClientKey)
	setEnvString("PH01_AUTH_SERVER_NAME", cfg.PH01Auth.ServerName)
	setEnvString("PH01_GEOIP_API_URL", cfg.PH01Auth.GeoIPAPIURL)
	setEnvInt("PH01_GEOIP_API_TIMEOUT_MS", cfg.PH01Auth.GeoIPAPITimeoutMS)
	setEnvInt("PH01_GEOIP_CACHE_TTL_HOURS", cfg.PH01Auth.GeoIPCacheTTLHour)
	setEnvString("PH01_GEOIP_DB_PATH", cfg.PH01Auth.GeoIPDBPath)

	setEnvString("GOOGLE_ANALYTICS_ID", cfg.Analytics.GoogleAnalyticsID)
	setEnvString("UMAMI_WEBSITE_ID", cfg.Analytics.UmamiWebsiteID)
	setEnvString("UMAMI_SCRIPT_URL", cfg.Analytics.UmamiScriptURL)
	return nil
}

func PH01AuthConfigured() bool {
	return strings.TrimSpace(os.Getenv("PH01_AUTH_BASE_URL")) != ""
}

func setEnvString(key, value string) {
	value = strings.TrimSpace(value)
	if value == "" {
		return
	}
	_ = os.Setenv(key, value)
}

func setEnvStringPtr(key string, value *string) {
	if value == nil {
		return
	}
	setEnvString(key, *value)
}

func setEnvRawStringPtr(key string, value *string) {
	if value == nil {
		return
	}
	_ = os.Setenv(key, *value)
}

func setEnvInt(key string, value int) {
	if value <= 0 {
		return
	}
	_ = os.Setenv(key, intString(value))
}

func setEnvBool(key string, value *bool) {
	if value == nil {
		return
	}
	if *value {
		_ = os.Setenv(key, "true")
		return
	}
	_ = os.Setenv(key, "false")
}

func setEnvList(key string, values []string) {
	cleaned := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			cleaned = append(cleaned, value)
		}
	}
	if len(cleaned) == 0 {
		return
	}
	_ = os.Setenv(key, strings.Join(cleaned, ","))
}

func intString(value int) string {
	return strconv.Itoa(value)
}
