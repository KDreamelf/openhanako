package config

import (
	"fmt"
	"os"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclwrite"
	"github.com/zclconf/go-cty/cty"
)

// UpdateSMTPBlock rewrites one smtp block in the HCL config file.
func UpdateSMTPBlock(path string, smtp *SMTP) error {
	if smtp == nil {
		return fmt.Errorf("smtp config is nil")
	}
	if smtp.Name == "" {
		return fmt.Errorf("smtp name is required")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read config: %w", err)
	}
	file, diags := hclwrite.ParseConfig(raw, path, hcl.InitialPos)
	if diags.HasErrors() {
		return fmt.Errorf("parse config: %s", diags.Error())
	}

	body := file.Body()
	block := findLabeledBlock(body, "smtp", smtp.Name)
	if block == nil {
		block = body.AppendNewBlock("smtp", []string{smtp.Name})
	}
	smtpBody := block.Body()
	smtpBody.SetAttributeValue("enabled", cty.BoolVal(smtp.Enabled))
	smtpBody.SetAttributeValue("host", cty.StringVal(smtp.Host))
	smtpBody.SetAttributeValue("port", cty.NumberIntVal(int64(smtp.Port)))
	smtpBody.SetAttributeValue("username", cty.StringVal(smtp.Username))
	smtpBody.SetAttributeValue("password", cty.StringVal(smtp.Password))
	smtpBody.SetAttributeValue("from", cty.StringVal(smtp.From))
	smtpBody.SetAttributeValue("tls_mode", cty.StringVal(smtp.TLSMode))

	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("stat config: %w", err)
	}
	if err := os.WriteFile(path, file.Bytes(), info.Mode().Perm()); err != nil {
		return fmt.Errorf("write config: %w", err)
	}
	return nil
}

func findLabeledBlock(body *hclwrite.Body, blockType, label string) *hclwrite.Block {
	for _, block := range body.Blocks() {
		labels := block.Labels()
		if block.Type() == blockType && len(labels) == 1 && labels[0] == label {
			return block
		}
	}
	return nil
}
