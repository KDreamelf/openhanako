/// Agent 数据类（与 legacy core/agent.js 对齐）。
class Agent {
  Agent({
    required this.id,
    required this.name,
    this.yuan = 'hanako',
    this.identity,
    this.ishiki,
    this.avatarPath,
    this.isPrimary = false,
  });

  final String id;
  final String name;

  /// 源模板：hanako / butter / ming
  final String yuan;

  /// identity.md 内容（身份描述）
  final String? identity;

  /// ishiki.md 内容（意识流模板）
  final String? ishiki;

  /// 本地头像文件路径。
  final String? avatarPath;

  /// 是否为主 agent（preferences.json:primaryAgent）
  final bool isPrimary;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'yuan': yuan,
    if (identity != null) 'identity': identity,
    if (ishiki != null) 'ishiki': ishiki,
    if (avatarPath != null) 'avatarPath': avatarPath,
    'isPrimary': isPrimary,
  };
}
