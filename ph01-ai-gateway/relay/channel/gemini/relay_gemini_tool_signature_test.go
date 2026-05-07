package gemini

import (
	"encoding/json"
	"testing"

	"github.com/QuantumNous/new-api/constant"
	"github.com/QuantumNous/new-api/dto"
	relaycommon "github.com/QuantumNous/new-api/relay/common"
	"github.com/stretchr/testify/require"
)

func TestCovertOpenAI2GeminiPreservesToolCallThoughtSignature(t *testing.T) {
	rawToolCalls := json.RawMessage(`[
		{
			"id": "call_1",
			"type": "function",
			"function": {
				"name": "ls",
				"arguments": "{\"path\":\".\"}",
				"thought_signature": "sig_from_gemini"
			}
		}
	]`)
	request := dto.GeneralOpenAIRequest{
		Model: "gemini-2.5-flash",
		Messages: []dto.Message{
			{Role: "user", Content: "列出当前目录"},
			{Role: "assistant", Content: "", ToolCalls: rawToolCalls},
			{Role: "tool", ToolCallId: "call_1", Content: `{"ok":true}`},
		},
	}
	info := &relaycommon.RelayInfo{
		ChannelMeta: &relaycommon.ChannelMeta{
			ChannelType:       constant.ChannelTypeGemini,
			UpstreamModelName: "gemini-2.5-flash",
		},
	}

	converted, err := CovertOpenAI2Gemini(nil, request, info)
	require.NoError(t, err)
	require.Len(t, converted.Contents, 3)
	require.Equal(t, "model", converted.Contents[1].Role)
	require.Len(t, converted.Contents[1].Parts, 1)
	require.JSONEq(
		t,
		`"sig_from_gemini"`,
		string(converted.Contents[1].Parts[0].ThoughtSignature),
	)
}

func TestCovertOpenAI2GeminiDoesNotSynthesizeMissingToolCallThoughtSignature(t *testing.T) {
	rawToolCalls := json.RawMessage(`[
		{
			"id": "call_1",
			"type": "function",
			"function": {
				"name": "ls",
				"arguments": "{\"path\":\".\"}"
			}
		},
		{
			"id": "call_2",
			"type": "function",
			"function": {
				"name": "read",
				"arguments": "{\"path\":\"README.md\"}"
			}
		}
	]`)
	request := dto.GeneralOpenAIRequest{
		Model: "gemini-2.5-flash",
		Messages: []dto.Message{
			{Role: "user", Content: "检查项目"},
			{Role: "assistant", Content: "", ToolCalls: rawToolCalls},
		},
	}
	info := &relaycommon.RelayInfo{
		ChannelMeta: &relaycommon.ChannelMeta{
			ChannelType:       constant.ChannelTypeGemini,
			UpstreamModelName: "gemini-2.5-flash",
		},
	}

	converted, err := CovertOpenAI2Gemini(nil, request, info)
	require.NoError(t, err)
	require.Len(t, converted.Contents, 2)
	require.Equal(t, "model", converted.Contents[1].Role)
	require.Len(t, converted.Contents[1].Parts, 2)
	require.Empty(t, converted.Contents[1].Parts[0].ThoughtSignature)
	require.Empty(t, converted.Contents[1].Parts[1].ThoughtSignature)

	audit := InspectFunctionCallThoughtSignatures(converted)
	require.Equal(t, 2, audit.Total)
	require.Equal(t, 0, audit.Signed)
	require.Equal(t, 2, audit.MissingCount())
	require.Contains(t, audit.MissingSummary(8), "name=ls")
	require.Contains(t, audit.MissingSummary(8), "name=read")
}

func TestInspectFunctionCallThoughtSignaturesJSONReportsMissingSignatures(t *testing.T) {
	input := []byte(`{
		"contents": [
			{
				"role": "model",
				"parts": [
					{"functionCall": {"name": "ls", "args": {"path": "."}}},
					{"functionCall": {"name": "read", "args": {"path": "README.md"}}, "thoughtSignature": "keep_me"}
				]
			}
		]
	}`)

	audit, err := InspectFunctionCallThoughtSignaturesJSON(input)

	require.NoError(t, err)
	require.Equal(t, 2, audit.Total)
	require.Equal(t, 1, audit.Signed)
	require.Equal(t, 1, audit.MissingCount())
	require.Equal(t, "thoughtSignature", audit.SignedParts[0].FieldName)
	require.Equal(t, "ls", audit.Missing[0].FunctionName)
}

func TestSummarizeGeminiRequestShapeJSONRedactsContentAndArgs(t *testing.T) {
	input := []byte(`{
		"contents": [
			{"role": "user", "parts": [{"text": "secret prompt"}]},
			{"role": "model", "parts": [{"functionCall": {"name": "ls", "args": {"path": "secret"}}, "thoughtSignature": "sig"}]},
			{"role": "user", "parts": [{"functionResponse": {"name": "ls", "response": {"content": "secret result"}}}]}
		]
	}`)

	shape, err := SummarizeGeminiRequestShapeJSON(input, 12)

	require.NoError(t, err)
	require.Contains(t, shape, "0:user[0:text]")
	require.Contains(t, shape, "1:model[0:functionCall(ls sig_field=thoughtSignature")
	require.Contains(t, shape, "2:user[0:functionResponse(ls)]")
	require.NotContains(t, shape, "secret")
}

func TestGetResponseToolCallIncludesThoughtSignature(t *testing.T) {
	call := getResponseToolCall(&dto.GeminiPart{
		FunctionCall: &dto.FunctionCall{
			FunctionName: "ls",
			Arguments: map[string]interface{}{
				"path": ".",
			},
		},
		ThoughtSignature: json.RawMessage(`"sig_from_gemini"`),
	})

	require.NotNil(t, call)
	require.Equal(t, "ls", call.Function.Name)
	require.JSONEq(t, `"sig_from_gemini"`, string(call.Function.ThoughtSignature))
}
