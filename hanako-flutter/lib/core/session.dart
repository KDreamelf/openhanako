/// Session 数据类（对齐 legacy core/session.js）。
class Session {
  Session({
    required this.path,
    required this.title,
    required this.agentId,
    this.cwd,
    this.memoryEnabled = true,
  });

  /// session 文件路径（HANA_HOME/agents/<id>/sessions/<sessionId>.jsonl）
  final String path;
  String title;
  final String agentId;
  String? cwd;
  bool memoryEnabled;

  Map<String, dynamic> toJson() => {
        'path': path,
        'title': title,
        'agentId': agentId,
        if (cwd != null) 'cwd': cwd,
        'memoryEnabled': memoryEnabled,
      };
}
