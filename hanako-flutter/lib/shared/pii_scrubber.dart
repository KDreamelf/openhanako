/// PII (Personal Identifiable Information) 脱敏工具。
///
/// 扫描文本中 4 类常见 PII 模式，用 `[REDACTED:XXX]` 替换：
/// - 16 位银行卡号（含可选 - / 空格分隔）→ `[REDACTED:CARD]`
/// - 中国大陆 18 位身份证（17 位数字 + 1 位数字/X）→ `[REDACTED:ID]`
/// - 中国大陆 11 位手机号（`1[3-9]xxxxxxxxx`）→ `[REDACTED:PHONE]`
/// - 邮箱（基础模式）→ `[REDACTED:EMAIL]`
///
/// 局限：只识别这 4 种格式化模式，不识别姓名/地址/工号/上下文敏感语义。
/// 这些场景需要 LLM-based 脱敏配合。本工具适合作为 LLM 脱敏前/后的
/// 快速兜底，或写入"经验"等明文落盘路径时的最低保护。
///
/// 用 `\b` 词边界避免误吞掉子串（如订单号 "11234567890XX" 不会被当作手机号）。
String scrubPii(String text) {
  var out = text;
  out = out.replaceAll(
    RegExp(r'\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b'),
    '[REDACTED:CARD]',
  );
  out = out.replaceAll(RegExp(r'\b\d{17}[\dXx]\b'), '[REDACTED:ID]');
  out = out.replaceAll(RegExp(r'\b1[3-9]\d{9}\b'), '[REDACTED:PHONE]');
  out = out.replaceAll(
    RegExp(r'\b[\w.+-]+@[\w-]+\.[\w.-]+\b'),
    '[REDACTED:EMAIL]',
  );
  return out;
}
