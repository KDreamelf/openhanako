package markdowntools

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/constant"
	"github.com/QuantumNous/new-api/dto"
	"github.com/gin-gonic/gin"
)

const (
	contextRegistryKey    = "ph01_markdown_ast_tool_registry"
	contextStreamStateKey = "ph01_markdown_ast_tool_stream_state"

	toolCallType = "function"
)

var (
	callStartRegexp = regexp.MustCompile(`<\s*[-*\s]{2,}\s*工具调用开始\s*[:：]\s*(.+?)\s*[-*\s]{2,}\s*>`)
	callEndRegexp   = regexp.MustCompile(`<\s*[-*\s]{2,}\s*工具调用结束\s*[-*\s]{2,}\s*>`)
	headingRegexp   = regexp.MustCompile(`^(#{1,6})\s+(.+?)\s*$`)

	ErrIncompleteToolCall = errors.New("Markdown AST 工具调用未闭合：上游模型在工具调用块结束前中断")
)

type Registry struct {
	Tools map[string]*ToolDefinition
	Order []string
}

type ToolDefinition struct {
	Name        string
	Description string
	Parameters  any
	Schema      *FieldSchema
}

type FieldSchema struct {
	Type        string
	Description string
	Required    bool
	Properties  map[string]*FieldSchema
}

type ParsedCall struct {
	ID        string
	Name      string
	Arguments string
}

type markerMatch struct {
	Start int
	End   int
	Name  string
}

type streamSegment struct {
	Text  string
	Call  *ParsedCall
	Index int
}

type streamState struct {
	Buffer          string
	InBlock         bool
	BlockToolName   string
	ToolIndex       int
	EmittedToolCall bool
}

func ApplyRequest(c *gin.Context, request *dto.GeneralOpenAIRequest) error {
	if request == nil {
		return nil
	}

	registry := BuildRegistry(request.Tools)
	if registry.Empty() {
		request.Tools = nil
		request.ToolChoice = nil
		request.Functions = nil
		request.FunctionCall = nil
		request.ParallelTooCalls = nil
		return nil
	}

	c.Set(contextRegistryKey, registry)

	callNames := make(map[string]string)
	messages := make([]dto.Message, 0, len(request.Messages)+1)
	messages = append(messages, dto.Message{
		Role:    request.GetSystemRoleName(),
		Content: BuildPrompt(registry),
	})

	for _, message := range request.Messages {
		switch message.Role {
		case "assistant":
			toolCalls := message.ParseToolCalls()
			if len(toolCalls) == 0 {
				messages = append(messages, message)
				continue
			}
			content := strings.TrimSpace(message.StringContent())
			blocks := make([]string, 0, len(toolCalls))
			for _, call := range toolCalls {
				name := strings.TrimSpace(call.Function.Name)
				if name == "" {
					continue
				}
				if call.ID != "" {
					callNames[call.ID] = name
				}
				blocks = append(blocks, FormatCallBlock(name, call.Function.Arguments))
			}
			if len(blocks) > 0 {
				if content != "" {
					content += "\n\n"
				}
				content += strings.Join(blocks, "\n\n")
			}
			message.Content = content
			message.ToolCalls = nil
			messages = append(messages, message)
		case "tool", "function":
			name := ""
			if message.Name != nil {
				name = strings.TrimSpace(*message.Name)
			}
			if name == "" && message.ToolCallId != "" {
				name = callNames[message.ToolCallId]
			}
			if name == "" {
				name = "unknown_tool"
			}
			content := message.StringContent()
			if content == "" && message.Content != nil {
				raw, err := json.Marshal(message.Content)
				if err == nil {
					content = string(raw)
				}
			}
			messages = append(messages, dto.Message{
				Role:    "user",
				Content: FormatReturnBlock(name, message.ToolCallId, content),
			})
		default:
			messages = append(messages, message)
		}
	}

	request.Messages = messages
	request.Tools = nil
	request.ToolChoice = nil
	request.Functions = nil
	request.FunctionCall = nil
	request.ParallelTooCalls = nil
	return nil
}

func BuildRegistry(tools []dto.ToolCallRequest) *Registry {
	registry := &Registry{
		Tools: make(map[string]*ToolDefinition),
		Order: make([]string, 0, len(tools)),
	}

	for _, tool := range tools {
		if tool.Type != "" && tool.Type != toolCallType {
			continue
		}
		name := strings.TrimSpace(tool.Function.Name)
		if name == "" {
			continue
		}
		if _, exists := registry.Tools[name]; exists {
			continue
		}

		registry.Tools[name] = &ToolDefinition{
			Name:        name,
			Description: tool.Function.Description,
			Parameters:  tool.Function.Parameters,
			Schema:      ParseSchema(tool.Function.Parameters),
		}
		registry.Order = append(registry.Order, name)
	}
	return registry
}

func (r *Registry) Empty() bool {
	return r == nil || len(r.Tools) == 0
}

func (r *Registry) Get(name string) *ToolDefinition {
	if r == nil {
		return nil
	}
	return r.Tools[name]
}

func BuildPrompt(registry *Registry) string {
	var b strings.Builder
	b.WriteString("工具调用协议：当前渠道启用了 Markdown AST 工具调用。你可以使用下列工具，但不要输出 JSON、function_call 或 provider 原生工具调用对象。\n")
	b.WriteString("当你需要调用工具时，只输出一个或多个完整工具调用块；不要在工具调用块外夹杂解释文字。格式必须如下：\n\n")
	b.WriteString("<----工具调用开始：tool_name---->\n")
	b.WriteString("# parameter_name\n")
	b.WriteString("parameter value\n\n")
	b.WriteString("# nested_object\n")
	b.WriteString("## child_parameter\n")
	b.WriteString("child value\n")
	b.WriteString("<----工具调用结束---->\n\n")
	b.WriteString("工具执行结果会以同构的 Markdown 工具返回块出现在后续消息里。读取工具返回后，继续完成用户任务。\n\n")
	b.WriteString("可用工具：\n")
	for _, name := range registry.Order {
		tool := registry.Tools[name]
		b.WriteString("\n## ")
		b.WriteString(tool.Name)
		b.WriteString("\n")
		if strings.TrimSpace(tool.Description) != "" {
			b.WriteString(tool.Description)
			b.WriteString("\n")
		}
		b.WriteString(formatSchemaForPrompt(tool.Schema, 0))
	}
	return strings.TrimSpace(b.String())
}

func FormatCallBlock(name string, arguments string) string {
	var b strings.Builder
	b.WriteString("<----工具调用开始：")
	b.WriteString(name)
	b.WriteString("---->\n")
	if strings.TrimSpace(arguments) == "" {
		b.WriteString("<----工具调用结束---->")
		return b.String()
	}

	var parsed map[string]any
	if err := json.Unmarshal([]byte(arguments), &parsed); err == nil {
		b.WriteString(formatMarkdownObject(parsed, 1))
	} else {
		b.WriteString("# arguments\n")
		b.WriteString(arguments)
		if !strings.HasSuffix(arguments, "\n") {
			b.WriteString("\n")
		}
	}
	b.WriteString("<----工具调用结束---->")
	return b.String()
}

func FormatReturnBlock(name string, toolCallID string, content string) string {
	var b strings.Builder
	b.WriteString("<----工具返回开始：")
	b.WriteString(name)
	b.WriteString("---->\n")
	b.WriteString("# status\nsuccess\n\n")
	if strings.TrimSpace(toolCallID) != "" {
		b.WriteString("# tool_call_id\n")
		b.WriteString(toolCallID)
		b.WriteString("\n\n")
	}
	b.WriteString("# content\n")
	b.WriteString(content)
	if !strings.HasSuffix(content, "\n") {
		b.WriteString("\n")
	}
	b.WriteString("<----工具返回结束---->")
	return b.String()
}

func TransformTextResponse(c *gin.Context, response *dto.OpenAITextResponse) (bool, error) {
	registry := registryFromContext(c)
	if registry.Empty() || response == nil {
		return false, nil
	}

	modified := false
	for choiceIdx := range response.Choices {
		message := &response.Choices[choiceIdx].Message
		content := message.StringContent()
		if hasIncompleteToolCall(content) {
			return false, ErrIncompleteToolCall
		}
		calls, cleaned, ok := ParseToolCallsFromText(content, registry)
		if !ok {
			continue
		}
		toolCalls := make([]dto.ToolCallResponse, 0, len(calls))
		for i := range calls {
			toolCalls = append(toolCalls, parsedCallToResponse(calls[i], nil))
		}
		if strings.TrimSpace(cleaned) == "" {
			message.Content = nil
		} else {
			message.Content = strings.TrimSpace(cleaned)
		}
		message.SetToolCalls(toolCalls)
		response.Choices[choiceIdx].FinishReason = constant.FinishReasonToolCalls
		modified = true
	}
	return modified, nil
}

func TransformStreamResponse(c *gin.Context, response *dto.ChatCompletionsStreamResponse) ([]dto.ChatCompletionsStreamResponse, bool, error) {
	registry := registryFromContext(c)
	if registry.Empty() || response == nil {
		return nil, false, nil
	}

	state := streamStateFromContext(c)
	outputs := make([]dto.ChatCompletionsStreamResponse, 0, 1)
	modified := false

	for choiceIdx := range response.Choices {
		choice := response.Choices[choiceIdx]
		content := choice.Delta.GetContentString()
		if content == "" {
			if state.EmittedToolCall && choice.FinishReason != nil {
				toolFinishReason := constant.FinishReasonToolCalls
				response.Choices[choiceIdx].FinishReason = &toolFinishReason
				modified = true
			}
			continue
		}

		segments, err := state.Accept(content, registry)
		if err != nil {
			return nil, false, err
		}
		modified = true
		response.Choices[choiceIdx].Delta.Content = nil
		for _, segment := range segments {
			outputs = append(outputs, streamSegmentToResponse(response, choiceIdx, segment))
		}
	}

	if !modified {
		return nil, false, nil
	}

	hasRemainingPayload := false
	for _, choice := range response.Choices {
		if choice.Delta.GetContentString() != "" ||
			choice.Delta.GetReasoningContent() != "" ||
			len(choice.Delta.ToolCalls) > 0 ||
			choice.Delta.Role != "" ||
			choice.FinishReason != nil {
			hasRemainingPayload = true
			break
		}
	}
	if hasRemainingPayload {
		outputs = append(outputs, *response)
	}
	return outputs, true, nil
}

func FlushStream(c *gin.Context, response *dto.ChatCompletionsStreamResponse) ([]dto.ChatCompletionsStreamResponse, bool, error) {
	registry := registryFromContext(c)
	if registry.Empty() {
		return nil, false, nil
	}
	state := streamStateFromContext(c)
	segments, err := state.Flush()
	if err != nil {
		return nil, false, err
	}
	if len(segments) == 0 {
		return nil, false, nil
	}
	outputs := make([]dto.ChatCompletionsStreamResponse, 0, len(segments))
	for _, segment := range segments {
		outputs = append(outputs, streamSegmentToResponse(response, 0, segment))
	}
	return outputs, true, nil
}

func ParseToolCallsFromText(text string, registry *Registry) ([]ParsedCall, string, bool) {
	if strings.TrimSpace(text) == "" {
		return nil, text, false
	}

	offset := 0
	var cleaned strings.Builder
	calls := make([]ParsedCall, 0)
	for offset < len(text) {
		start, ok := findCallStart(text[offset:])
		if !ok {
			cleaned.WriteString(text[offset:])
			break
		}
		start.Start += offset
		start.End += offset

		endLoc := callEndRegexp.FindStringIndex(text[start.End:])
		if endLoc == nil {
			cleaned.WriteString(text[offset:])
			break
		}
		endStart := start.End + endLoc[0]
		endEnd := start.End + endLoc[1]
		cleaned.WriteString(text[offset:start.Start])

		args := ParseArgumentsMarkdown(text[start.End:endStart], registry.Get(start.Name))
		calls = append(calls, ParsedCall{
			ID:        fmt.Sprintf("call_%s", common.GetUUID()),
			Name:      start.Name,
			Arguments: args,
		})
		offset = endEnd
	}
	return calls, cleaned.String(), len(calls) > 0
}

func ParseArgumentsMarkdown(block string, tool *ToolDefinition) string {
	args := parseMarkdownFields(block, tool)
	if len(args) == 0 {
		return "{}"
	}
	raw, err := json.Marshal(args)
	if err != nil {
		return "{}"
	}
	return string(raw)
}

func ParseSchema(parameters any) *FieldSchema {
	raw, err := json.Marshal(parameters)
	if err != nil || len(raw) == 0 || string(raw) == "null" {
		return &FieldSchema{Type: "object", Properties: map[string]*FieldSchema{}}
	}
	var schema map[string]any
	if err := json.Unmarshal(raw, &schema); err != nil {
		return &FieldSchema{Type: "object", Properties: map[string]*FieldSchema{}}
	}
	return parseFieldSchema(schema, false)
}

func parseFieldSchema(schema map[string]any, required bool) *FieldSchema {
	field := &FieldSchema{
		Type:       stringFromAny(schema["type"]),
		Required:   required,
		Properties: map[string]*FieldSchema{},
	}
	field.Description = stringFromAny(schema["description"])

	requiredNames := map[string]bool{}
	if requiredList, ok := schema["required"].([]any); ok {
		for _, item := range requiredList {
			requiredNames[stringFromAny(item)] = true
		}
	}
	if props, ok := schema["properties"].(map[string]any); ok {
		keys := make([]string, 0, len(props))
		for key := range props {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			propMap, ok := props[key].(map[string]any)
			if !ok {
				continue
			}
			field.Properties[key] = parseFieldSchema(propMap, requiredNames[key])
		}
	}
	return field
}

func parseMarkdownFields(block string, tool *ToolDefinition) map[string]any {
	result := map[string]any{}
	lines := strings.Split(strings.ReplaceAll(block, "\r\n", "\n"), "\n")
	var currentPath []string
	var currentSchema *FieldSchema
	var currentValue strings.Builder

	flush := func() {
		if len(currentPath) == 0 {
			currentValue.Reset()
			return
		}
		value := strings.TrimSpace(currentValue.String())
		if value != "" {
			setNestedValue(result, currentPath, convertValueBySchema(value, currentSchema))
		}
		currentValue.Reset()
	}

	for _, line := range lines {
		matches := headingRegexp.FindStringSubmatch(line)
		if matches == nil {
			currentValue.WriteString(line)
			currentValue.WriteString("\n")
			continue
		}

		level := len(matches[1])
		name := strings.TrimSpace(matches[2])
		nextPath, nextSchema, ok := resolveHeading(tool, currentPath, level, name)
		if !ok {
			currentValue.WriteString(line)
			currentValue.WriteString("\n")
			continue
		}

		flush()
		currentPath = nextPath
		currentSchema = nextSchema
	}
	flush()

	return result
}

func resolveHeading(tool *ToolDefinition, currentPath []string, level int, name string) ([]string, *FieldSchema, bool) {
	root := (*FieldSchema)(nil)
	if tool != nil {
		root = tool.Schema
	}
	if root == nil || len(root.Properties) == 0 {
		path := append([]string{}, currentPath...)
		if level <= 0 {
			level = 1
		}
		if len(path) >= level {
			path = path[:level-1]
		}
		path = append(path, name)
		return path, nil, true
	}

	if level == 1 {
		schema, ok := root.Properties[name]
		return []string{name}, schema, ok
	}

	if len(currentPath) < level-1 {
		return nil, nil, false
	}
	parentPath := append([]string{}, currentPath[:level-1]...)
	parentSchema := schemaAtPath(root, parentPath)
	if parentSchema == nil || len(parentSchema.Properties) == 0 {
		return nil, nil, false
	}
	schema, ok := parentSchema.Properties[name]
	if !ok {
		return nil, nil, false
	}
	path := append(parentPath, name)
	return path, schema, true
}

func schemaAtPath(root *FieldSchema, path []string) *FieldSchema {
	current := root
	for _, item := range path {
		if current == nil {
			return nil
		}
		current = current.Properties[item]
	}
	return current
}

func setNestedValue(result map[string]any, path []string, value any) {
	current := result
	for i, item := range path {
		if i == len(path)-1 {
			current[item] = value
			return
		}
		next, ok := current[item].(map[string]any)
		if !ok {
			next = map[string]any{}
			current[item] = next
		}
		current = next
	}
}

func convertValueBySchema(value string, schema *FieldSchema) any {
	if schema == nil {
		return autoConvertValue(value)
	}
	switch schema.Type {
	case "integer":
		if parsed, err := strconv.ParseInt(value, 10, 64); err == nil {
			return parsed
		}
	case "number":
		if parsed, err := strconv.ParseFloat(value, 64); err == nil {
			return parsed
		}
	case "boolean":
		if parsed, err := strconv.ParseBool(strings.ToLower(value)); err == nil {
			return parsed
		}
	case "array", "object":
		var parsed any
		if err := json.Unmarshal([]byte(value), &parsed); err == nil {
			return parsed
		}
	}
	return value
}

func autoConvertValue(value string) any {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return ""
	}
	if strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[") {
		var parsed any
		if err := json.Unmarshal([]byte(trimmed), &parsed); err == nil {
			return parsed
		}
	}
	return value
}

func formatMarkdownObject(value any, level int) string {
	var b strings.Builder
	switch typed := value.(type) {
	case map[string]any:
		keys := make([]string, 0, len(typed))
		for key := range typed {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			b.WriteString(strings.Repeat("#", level))
			b.WriteString(" ")
			b.WriteString(key)
			b.WriteString("\n")
			switch child := typed[key].(type) {
			case map[string]any:
				b.WriteString(formatMarkdownObject(child, level+1))
			default:
				b.WriteString(formatValueForMarkdown(child))
				b.WriteString("\n\n")
			}
		}
	default:
		b.WriteString(formatValueForMarkdown(value))
		b.WriteString("\n")
	}
	return b.String()
}

func formatValueForMarkdown(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case nil:
		return ""
	default:
		raw, err := json.MarshalIndent(typed, "", "  ")
		if err == nil {
			return string(raw)
		}
		return fmt.Sprintf("%v", typed)
	}
}

func formatSchemaForPrompt(schema *FieldSchema, depth int) string {
	if schema == nil || len(schema.Properties) == 0 {
		return "- 参数：无结构化 schema 或未声明参数。\n"
	}
	keys := make([]string, 0, len(schema.Properties))
	for key := range schema.Properties {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, key := range keys {
		field := schema.Properties[key]
		b.WriteString(strings.Repeat("  ", depth))
		b.WriteString("- ")
		b.WriteString(key)
		if field.Type != "" {
			b.WriteString(" (")
			b.WriteString(field.Type)
			if field.Required {
				b.WriteString(", required")
			}
			b.WriteString(")")
		} else if field.Required {
			b.WriteString(" (required)")
		}
		if strings.TrimSpace(field.Description) != "" {
			b.WriteString(": ")
			b.WriteString(field.Description)
		}
		b.WriteString("\n")
		if len(field.Properties) > 0 {
			b.WriteString(formatSchemaForPrompt(field, depth+1))
		}
	}
	return b.String()
}

func findCallStart(text string) (markerMatch, bool) {
	matches := callStartRegexp.FindStringSubmatchIndex(text)
	if matches == nil || len(matches) < 4 {
		return markerMatch{}, false
	}
	name := strings.TrimSpace(text[matches[2]:matches[3]])
	name = strings.Trim(name, "-* \t\r\n")
	if name == "" {
		return markerMatch{}, false
	}
	return markerMatch{Start: matches[0], End: matches[1], Name: name}, true
}

func (s *streamState) Accept(text string, registry *Registry) ([]streamSegment, error) {
	s.Buffer += text
	return s.drain(registry, false)
}

func (s *streamState) Flush() ([]streamSegment, error) {
	if s.Buffer == "" && !s.InBlock {
		return nil, nil
	}
	defer s.resetBlock()
	if s.InBlock {
		s.Buffer = ""
		return nil, ErrIncompleteToolCall
	}
	if strings.TrimSpace(s.Buffer) != "" && shouldHoldForPossibleStart(s.Buffer) {
		s.Buffer = ""
		return nil, ErrIncompleteToolCall
	}
	text := s.Buffer
	s.Buffer = ""
	return []streamSegment{{Text: text}}, nil
}

func (s *streamState) drain(registry *Registry, final bool) ([]streamSegment, error) {
	segments := make([]streamSegment, 0)
	for {
		if s.InBlock {
			endLoc := callEndRegexp.FindStringIndex(s.Buffer)
			if endLoc == nil {
				if final {
					flushed, err := s.Flush()
					if err != nil {
						return segments, err
					}
					segments = append(segments, flushed...)
				}
				return segments, nil
			}

			block := s.Buffer[:endLoc[0]]
			args := ParseArgumentsMarkdown(block, registry.Get(s.BlockToolName))
			call := &ParsedCall{
				ID:        fmt.Sprintf("call_%s", common.GetUUID()),
				Name:      s.BlockToolName,
				Arguments: args,
			}
			idx := s.ToolIndex
			s.ToolIndex++
			s.EmittedToolCall = true
			segments = append(segments, streamSegment{Call: call, Index: idx})
			s.Buffer = s.Buffer[endLoc[1]:]
			s.InBlock = false
			s.BlockToolName = ""
			continue
		}

		if s.Buffer == "" {
			return segments, nil
		}

		start, ok := findCallStart(s.Buffer)
		if ok {
			prefix := s.Buffer[:start.Start]
			if strings.TrimSpace(prefix) != "" {
				segments = append(segments, streamSegment{Text: prefix})
			}
			s.Buffer = s.Buffer[start.End:]
			s.InBlock = true
			s.BlockToolName = start.Name
			continue
		}

		if shouldHoldForPossibleStart(s.Buffer) {
			return segments, nil
		}

		segments = append(segments, streamSegment{Text: s.Buffer})
		s.Buffer = ""
		return segments, nil
	}
}

func shouldHoldForPossibleStart(buffer string) bool {
	trimmed := strings.TrimLeft(buffer, " \t\r\n")
	if trimmed == "" {
		return len(buffer) < 64
	}
	marker := "<----工具调用开始"
	if strings.HasPrefix(marker, trimmed) {
		return true
	}
	if strings.HasPrefix(trimmed, marker) && !strings.Contains(trimmed, ">") {
		return true
	}
	if strings.HasPrefix(trimmed, "<") && len(trimmed) < 12 {
		for _, ch := range trimmed {
			if ch != '<' && ch != '-' && ch != '*' && ch != ' ' && ch != '\t' {
				return false
			}
		}
		return true
	}
	return false
}

func (s *streamState) resetBlock() {
	s.InBlock = false
	s.BlockToolName = ""
}

func hasIncompleteToolCall(text string) bool {
	if strings.TrimSpace(text) == "" {
		return false
	}
	offset := 0
	foundCompleteCall := false
	for offset < len(text) {
		start, ok := findCallStart(text[offset:])
		if !ok {
			break
		}
		foundCompleteCall = true
		start.End += offset
		endLoc := callEndRegexp.FindStringIndex(text[start.End:])
		if endLoc == nil {
			return true
		}
		offset = start.End + endLoc[1]
	}
	if foundCompleteCall {
		return looksLikePartialCallStart(text[offset:])
	}
	return looksLikePartialCallStart(text)
}

func looksLikePartialCallStart(text string) bool {
	trimmed := strings.TrimLeft(text, " \t\r\n")
	if shouldHoldForPossibleStart(trimmed) && strings.TrimSpace(trimmed) != "" {
		return true
	}
	idx := strings.Index(trimmed, "工具调用开始")
	if idx < 0 {
		return false
	}
	prefix := trimmed[:idx]
	if !strings.Contains(prefix, "<") {
		return false
	}
	return !strings.Contains(trimmed[idx:], "工具调用结束")
}

func streamSegmentToResponse(base *dto.ChatCompletionsStreamResponse, choiceIdx int, segment streamSegment) dto.ChatCompletionsStreamResponse {
	response := dto.ChatCompletionsStreamResponse{
		Id:                base.Id,
		Object:            base.Object,
		Created:           base.Created,
		Model:             base.Model,
		SystemFingerprint: base.SystemFingerprint,
		Usage:             base.Usage,
		Choices: []dto.ChatCompletionsStreamResponseChoice{
			{
				Index: choiceIdx,
			},
		},
	}

	if segment.Call != nil {
		idx := segment.Index
		response.Choices[0].Delta.ToolCalls = []dto.ToolCallResponse{
			parsedCallToResponse(*segment.Call, &idx),
		}
		return response
	}

	response.Choices[0].Delta.SetContentString(segment.Text)
	return response
}

func parsedCallToResponse(call ParsedCall, index *int) dto.ToolCallResponse {
	response := dto.ToolCallResponse{
		ID:   call.ID,
		Type: toolCallType,
		Function: dto.FunctionResponse{
			Name:      call.Name,
			Arguments: call.Arguments,
		},
	}
	if index != nil {
		response.SetIndex(*index)
	}
	return response
}

func registryFromContext(c *gin.Context) *Registry {
	if c == nil {
		return nil
	}
	value, ok := c.Get(contextRegistryKey)
	if !ok {
		return nil
	}
	registry, _ := value.(*Registry)
	return registry
}

func streamStateFromContext(c *gin.Context) *streamState {
	if c == nil {
		return &streamState{}
	}
	value, ok := c.Get(contextStreamStateKey)
	if ok {
		if state, ok := value.(*streamState); ok {
			return state
		}
	}
	state := &streamState{}
	c.Set(contextStreamStateKey, state)
	return state
}

func stringFromAny(value any) string {
	if value == nil {
		return ""
	}
	if str, ok := value.(string); ok {
		return str
	}
	return fmt.Sprintf("%v", value)
}
