package model

import (
	"os"
	"strings"

	"github.com/QuantumNous/new-api/common"
)

func ApplyDeploymentOptionOverrides() {
	applyDeploymentDefault("SystemName", os.Getenv("PH01_SYSTEM_NAME"), "幻宙01", "", "New API")
	applyDeploymentDefault("theme.frontend", os.Getenv("PH01_FRONTEND_THEME"), "default", "", "classic")
	applyDeploymentDefault("ServerAddress", os.Getenv("FRONTEND_BASE_URL"), "", "", "http://localhost:3000")

	if value, ok := os.LookupEnv("PH01_LOGO"); ok {
		applyDeploymentOption("Logo", value, false)
	}
	if value, ok := os.LookupEnv("PH01_FOOTER"); ok {
		applyDeploymentOption("Footer", value, true)
	}
	if value, ok := os.LookupEnv("PH01_HOME_PAGE_CONTENT"); ok {
		applyDeploymentOption("HomePageContent", value, true)
	}
}

func applyDeploymentDefault(key string, envValue string, fallback string, oldValues ...string) {
	envValue = strings.TrimSpace(envValue)
	if envValue != "" {
		_ = UpdateOption(key, envValue)
		return
	}
	if fallback == "" {
		return
	}
	current := currentOptionValue(key)
	for _, oldValue := range oldValues {
		if current == oldValue {
			_ = UpdateOption(key, fallback)
			return
		}
	}
}

func applyDeploymentOption(key string, value string, allowEmpty bool) {
	if !allowEmpty {
		value = strings.TrimSpace(value)
		if value == "" {
			return
		}
	}
	_ = UpdateOption(key, value)
}

func currentOptionValue(key string) string {
	common.OptionMapRWMutex.RLock()
	defer common.OptionMapRWMutex.RUnlock()
	return common.OptionMap[key]
}
