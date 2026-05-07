package markdowntools

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/QuantumNous/new-api/constant"
	"github.com/QuantumNous/new-api/dto"
	"github.com/gin-gonic/gin"
)

func TestApplyRequestConvertsNativeToolsToMarkdownProtocol(t *testing.T) {
	gin.SetMode(gin.TestMode)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	stream := true
	request := &dto.GeneralOpenAIRequest{
		Model:  "gpt-4",
		Stream: &stream,
		Tools: []dto.ToolCallRequest{
			{
				Type: "function",
				Function: dto.FunctionRequest{
					Name:        "ls",
					Description: "List files",
					Parameters: map[string]any{
						"type": "object",
						"properties": map[string]any{
							"path": map[string]any{"type": "string"},
						},
						"required": []any{"path"},
					},
				},
			},
		},
		Messages: []dto.Message{
			{Role: "user", Content: "看看目录"},
			{
				Role:    "assistant",
				Content: "",
				ToolCalls: json.RawMessage(`[
					{"id":"call_1","type":"function","function":{"name":"ls","arguments":"{\"path\":\".\"}"}}
				]`),
			},
			{Role: "tool", ToolCallId: "call_1", Content: `{"files":["README.md"]}`},
		},
	}

	if err := ApplyRequest(c, request); err != nil {
		t.Fatalf("ApplyRequest returned error: %v", err)
	}
	if len(request.Tools) != 0 || request.ToolChoice != nil || request.Functions != nil || request.FunctionCall != nil {
		t.Fatalf("native tool fields were not removed: %#v", request)
	}
	if len(request.Messages) != 4 {
		t.Fatalf("unexpected message count: %d", len(request.Messages))
	}
	if !strings.Contains(request.Messages[0].StringContent(), "Markdown AST 工具调用") {
		t.Fatalf("missing protocol prompt: %s", request.Messages[0].StringContent())
	}
	if !strings.Contains(request.Messages[2].StringContent(), "<----工具调用开始：ls---->") {
		t.Fatalf("assistant tool call was not converted: %s", request.Messages[2].StringContent())
	}
	if request.Messages[3].Role != "user" || !strings.Contains(request.Messages[3].StringContent(), "<----工具返回开始：ls---->") {
		t.Fatalf("tool return was not converted: %#v", request.Messages[3])
	}
}

func TestParseToolCallsFromMarkdownAST(t *testing.T) {
	registry := BuildRegistry([]dto.ToolCallRequest{
		{
			Type: "function",
			Function: dto.FunctionRequest{
				Name: "run_command",
				Parameters: map[string]any{
					"type": "object",
					"properties": map[string]any{
						"command": map[string]any{"type": "string"},
						"options": map[string]any{
							"type": "object",
							"properties": map[string]any{
								"workdir": map[string]any{"type": "string"},
								"timeout": map[string]any{"type": "integer"},
							},
						},
					},
				},
			},
		},
	})

	calls, cleaned, ok := ParseToolCallsFromText(`先处理
<----工具调用开始：run_command---->
# command
git status --short

# options
## workdir
E:\CodeProgram\AI_Project\openhanako

## timeout
30
<----工具调用结束---->`, registry)

	if !ok || len(calls) != 1 {
		t.Fatalf("expected one parsed call, got ok=%v calls=%d", ok, len(calls))
	}
	if !strings.Contains(cleaned, "先处理") {
		t.Fatalf("cleaned content lost prefix: %q", cleaned)
	}
	if calls[0].Name != "run_command" {
		t.Fatalf("unexpected tool name: %s", calls[0].Name)
	}
	var args map[string]any
	if err := json.Unmarshal([]byte(calls[0].Arguments), &args); err != nil {
		t.Fatalf("arguments is not json: %v", err)
	}
	if args["command"] != "git status --short" {
		t.Fatalf("unexpected command: %#v", args["command"])
	}
	options, ok := args["options"].(map[string]any)
	if !ok || options["timeout"].(float64) != 30 {
		t.Fatalf("unexpected options: %#v", args["options"])
	}
}

func TestTransformStreamResponseBuffersMarkdownToolCall(t *testing.T) {
	gin.SetMode(gin.TestMode)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	registry := BuildRegistry([]dto.ToolCallRequest{
		{Type: "function", Function: dto.FunctionRequest{Name: "ls"}},
	})
	c.Set(contextRegistryKey, registry)

	chunk := func(content string) *dto.ChatCompletionsStreamResponse {
		return &dto.ChatCompletionsStreamResponse{
			Id:      "chatcmpl_1",
			Object:  "chat.completion.chunk",
			Created: 1,
			Model:   "model",
			Choices: []dto.ChatCompletionsStreamResponseChoice{
				{Index: 0, Delta: dto.ChatCompletionsStreamResponseChoiceDelta{Content: &content}},
			},
		}
	}

	out, modified, err := TransformStreamResponse(c, chunk("<----工具调用开始：ls---->\n# path\n"))
	if err != nil {
		t.Fatalf("first transform failed: %v", err)
	}
	if !modified || len(out) != 0 {
		t.Fatalf("expected first chunk to be buffered, modified=%v len=%d", modified, len(out))
	}

	out, modified, err = TransformStreamResponse(c, chunk(".\n<----工具调用结束---->"))
	if err != nil {
		t.Fatalf("second transform failed: %v", err)
	}
	if !modified || len(out) != 1 || len(out[0].Choices[0].Delta.ToolCalls) != 1 {
		t.Fatalf("expected tool call chunk, modified=%v out=%#v", modified, out)
	}
	if out[0].Choices[0].Delta.ToolCalls[0].Function.Name != "ls" {
		t.Fatalf("unexpected stream tool name: %#v", out[0].Choices[0].Delta.ToolCalls[0])
	}

	finishReason := constant.FinishReasonStop
	finish := &dto.ChatCompletionsStreamResponse{
		Id:      "chatcmpl_1",
		Object:  "chat.completion.chunk",
		Created: 1,
		Model:   "model",
		Choices: []dto.ChatCompletionsStreamResponseChoice{
			{Index: 0, FinishReason: &finishReason},
		},
	}
	out, modified, err = TransformStreamResponse(c, finish)
	if err != nil {
		t.Fatalf("finish transform failed: %v", err)
	}
	if !modified || len(out) != 1 || *out[0].Choices[0].FinishReason != constant.FinishReasonToolCalls {
		t.Fatalf("finish reason was not converted: modified=%v out=%#v", modified, out)
	}
}

func TestTransformStreamResponseBuffersSplitStartMarker(t *testing.T) {
	gin.SetMode(gin.TestMode)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	registry := BuildRegistry([]dto.ToolCallRequest{
		{
			Type: "function",
			Function: dto.FunctionRequest{
				Name: "ls",
				Parameters: map[string]any{
					"type": "object",
					"properties": map[string]any{
						"path": map[string]any{"type": "string"},
					},
				},
			},
		},
	})
	c.Set(contextRegistryKey, registry)

	chunk := func(content string) *dto.ChatCompletionsStreamResponse {
		return &dto.ChatCompletionsStreamResponse{
			Id:      "chatcmpl_1",
			Object:  "chat.completion.chunk",
			Created: 1,
			Model:   "model",
			Choices: []dto.ChatCompletionsStreamResponseChoice{
				{Index: 0, Delta: dto.ChatCompletionsStreamResponseChoiceDelta{Content: &content}},
			},
		}
	}

	for _, part := range []string{
		"<----工具调用开始：",
		"ls",
		"---->\n# path\n",
	} {
		out, modified, err := TransformStreamResponse(c, chunk(part))
		if err != nil {
			t.Fatalf("transform failed for %q: %v", part, err)
		}
		if !modified || len(out) != 0 {
			t.Fatalf("expected split marker part to be buffered, part=%q modified=%v out=%#v", part, modified, out)
		}
	}

	out, modified, err := TransformStreamResponse(c, chunk("E:\\CodeProgram\\AI_Project\\openhanako\n<----工具调用结束---->"))
	if err != nil {
		t.Fatalf("final transform failed: %v", err)
	}
	if !modified || len(out) != 1 || len(out[0].Choices[0].Delta.ToolCalls) != 1 {
		t.Fatalf("expected one tool call after split marker, modified=%v out=%#v", modified, out)
	}

	call := out[0].Choices[0].Delta.ToolCalls[0]
	if call.Function.Name != "ls" {
		t.Fatalf("unexpected tool name: %#v", call)
	}
	var args map[string]any
	if err := json.Unmarshal([]byte(call.Function.Arguments), &args); err != nil {
		t.Fatalf("arguments is not json: %v", err)
	}
	if args["path"] != "E:\\CodeProgram\\AI_Project\\openhanako" {
		t.Fatalf("unexpected path: %#v", args)
	}
}

func TestFlushStreamRejectsIncompleteMarkdownToolCall(t *testing.T) {
	gin.SetMode(gin.TestMode)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	registry := BuildRegistry([]dto.ToolCallRequest{
		{Type: "function", Function: dto.FunctionRequest{Name: "ls"}},
	})
	c.Set(contextRegistryKey, registry)

	content := "<----工具调用开始：ls---->\n# path\nE:\\CodeProgram\\AI_Project\\openhanako\n"
	_, modified, err := TransformStreamResponse(c, streamChunk(content))
	if err != nil {
		t.Fatalf("transform failed: %v", err)
	}
	if !modified {
		t.Fatalf("expected markdown stream state to be modified")
	}

	flushed, ok, err := FlushStream(c, streamChunk(""))
	if err == nil {
		t.Fatalf("expected incomplete tool call error, got flushed=%#v ok=%v", flushed, ok)
	}
	if err != ErrIncompleteToolCall {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(flushed) != 0 || ok {
		t.Fatalf("incomplete tool call must not flush text: ok=%v flushed=%#v", ok, flushed)
	}
}

func TestFlushStreamRejectsSplitStartMarker(t *testing.T) {
	gin.SetMode(gin.TestMode)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	registry := BuildRegistry([]dto.ToolCallRequest{
		{Type: "function", Function: dto.FunctionRequest{Name: "ls"}},
	})
	c.Set(contextRegistryKey, registry)

	_, modified, err := TransformStreamResponse(c, streamChunk("<----工具调用开始："))
	if err != nil {
		t.Fatalf("transform failed: %v", err)
	}
	if !modified {
		t.Fatalf("expected split marker to be buffered")
	}

	flushed, ok, err := FlushStream(c, streamChunk(""))
	if err == nil {
		t.Fatalf("expected split marker error, got flushed=%#v ok=%v", flushed, ok)
	}
	if err != ErrIncompleteToolCall {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(flushed) != 0 || ok {
		t.Fatalf("partial marker must not flush text: ok=%v flushed=%#v", ok, flushed)
	}
}

func TestTransformTextResponseRejectsIncompleteMarkdownToolCall(t *testing.T) {
	gin.SetMode(gin.TestMode)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	registry := BuildRegistry([]dto.ToolCallRequest{
		{Type: "function", Function: dto.FunctionRequest{Name: "ls"}},
	})
	c.Set(contextRegistryKey, registry)

	response := &dto.OpenAITextResponse{
		Choices: []dto.OpenAITextResponseChoice{
			{
				Message: dto.Message{
					Role:    "assistant",
					Content: "<----工具调用开始：ls---->\n# path\n.",
				},
			},
		},
	}

	modified, err := TransformTextResponse(c, response)
	if err == nil {
		t.Fatalf("expected incomplete tool call error")
	}
	if err != ErrIncompleteToolCall {
		t.Fatalf("unexpected error: %v", err)
	}
	if modified {
		t.Fatalf("incomplete tool call must not be marked modified")
	}
}

func streamChunk(content string) *dto.ChatCompletionsStreamResponse {
	return &dto.ChatCompletionsStreamResponse{
		Id:      "chatcmpl_1",
		Object:  "chat.completion.chunk",
		Created: 1,
		Model:   "model",
		Choices: []dto.ChatCompletionsStreamResponseChoice{
			{Index: 0, Delta: dto.ChatCompletionsStreamResponseChoiceDelta{Content: &content}},
		},
	}
}
