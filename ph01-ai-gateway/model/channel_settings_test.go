package model

import "testing"

func TestChannelValidateSettingsRejectsMarkdownASTWithPassThrough(t *testing.T) {
	setting := `{"pass_through_body_enabled":true,"markdown_ast_tool_calls_enabled":true}`
	channel := &Channel{Setting: &setting}

	if err := channel.ValidateSettings(); err == nil {
		t.Fatal("expected validation error")
	}
}

func TestChannelValidateSettingsAllowsMarkdownASTWithoutPassThrough(t *testing.T) {
	setting := `{"pass_through_body_enabled":false,"markdown_ast_tool_calls_enabled":true}`
	channel := &Channel{Setting: &setting}

	if err := channel.ValidateSettings(); err != nil {
		t.Fatalf("expected setting to be valid: %v", err)
	}
}
