import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/core/agent_runtime.dart';
import 'package:hanako/core/codex_agent_runtime.dart';
import 'package:hanako/windows_ops/windows_ops_capabilities.dart';
import 'package:hanako/windows_ops/windows_ops_client.dart';

void main() {
  test('Codex runtime registers standard tools for model use', () async {
    final runtime = await _buildRuntime();

    final toolNames = runtime.modelVisibleTools.map((tool) => tool.name);

    expect(toolNames, contains('exec_command'));
    expect(toolNames, contains('read_file'));
    expect(toolNames, contains('list_dir'));
    expect(toolNames, contains('search_text'));
    expect(toolNames, contains('apply_patch'));
    expect(toolNames, contains('request_user_input'));
    expect(toolNames, contains('request_permissions'));
    expect(toolNames, contains('view_image'));
    expect(toolNames, contains('tool_search'));
    expect(toolNames, contains('update_plan'));
    expect(toolNames, contains('spawn_agent'));
    expect(toolNames, contains('send_message'));
    expect(toolNames, contains('followup_task'));
    expect(toolNames, contains('wait_agent'));
    expect(toolNames, contains('close_agent'));
    expect(toolNames, contains('list_agents'));
    expect(toolNames, contains('get_goal'));
    expect(toolNames, contains('create_goal'));
    expect(toolNames, contains('update_goal'));
    expect(toolNames, isNot(contains('read')));
    expect(toolNames, isNot(contains('write')));
    expect(toolNames, isNot(contains('edit')));
    expect(toolNames, isNot(contains('bash')));
    expect(toolNames, isNot(contains('grep')));
    expect(toolNames, isNot(contains('find')));
    expect(toolNames, isNot(contains('ls')));
    expect(toolNames, isNot(contains('todo')));
    expect(toolNames, isNot(contains('delegate')));
    expect(toolNames, isNot(contains('ask_agent')));
    expect(toolNames, isNot(contains('message_agent')));
    expect(toolNames, isNot(contains('dm')));
    expect(toolNames, isNot(contains('channel')));
  });

  test('Codex tool descriptions carry PH01 usage constraints', () async {
    final runtime = await _buildRuntime();
    final tools = {
      for (final tool in runtime.modelVisibleTools) tool.name: tool,
    };

    expect(tools['read_file']?.description, contains('优先于 exec_command'));
    expect(tools['list_dir']?.description, contains('优先于 exec_command'));
    expect(tools['search_text']?.description, contains('优先于 exec_command'));
    expect(tools['exec_command']?.description, contains('读取文件用 read_file'));
    expect(tools['exec_command']?.description, contains('改用 apply_patch'));
    expect(tools['exec_command']?.description, contains('tty=true'));
    expect(
      tools['apply_patch']?.description,
      contains('编辑前必须先用 search_text/list_dir/read_file'),
    );
    expect(tools['apply_patch']?.description, contains('不要创建 Markdown/README'));
    expect(tools['apply_patch']?.description, contains('不要用 shell 写文件'));
    expect(tools['request_user_input']?.description, contains('推荐项放第一'));
    expect(tools['request_permissions']?.description, contains('如果被拒绝'));
    expect(tools['spawn_agent']?.description, contains('不要委托自己尚未理解的问题'));
    expect(
      tools['spawn_agent']?.description,
      contains('read_file/list_dir/search_text'),
    );
    expect(tools['wait_agent']?.description, contains('不要用 sleep 或轮询替代'));
    expect(tools['update_plan']?.description, contains('最多保持一个 in_progress'));
    expect(tools['tool_search']?.description, contains('不要猜测不存在的工具名'));
    expect(tools['web_fetch']?.description, contains('URL 必须完整有效'));
    expect(tools['web_search']?.description, contains('附上来源链接'));
    expect(
      tools['browser']?.description,
      contains('已知 URL 的静态内容优先用 web_fetch'),
    );
    expect(
      tools['browser']?.description,
      contains('避免触发 alert/confirm/prompt'),
    );
  });

  test('Codex tool schemas expose PH01 fields only', () async {
    final runtime = await _buildRuntime();
    final tools = {
      for (final tool in runtime.modelVisibleTools) tool.name: tool,
    };

    expect(_toolPropertyNames(tools['read_file']), {
      'path',
      'start_line',
      'end_line',
    });
    expect(_toolPropertyNames(tools['list_dir']), {
      'dir_path',
      'depth',
      'limit',
    });
    expect(_toolPropertyNames(tools['search_text']), {
      'pattern',
      'path',
      'regex',
      'case_sensitive',
      'glob',
      'limit',
    });
    expect(
      _toolPropertyNames(tools['exec_command']),
      containsAll(<String>{'cmd', 'workdir', 'tty'}),
    );
    expect(_toolPropertyNames(tools['apply_patch']), {'patch'});
    expect(_toolPropertyNames(tools['tool_search']), {'query', 'limit'});
    expect(_toolPropertyNames(tools['web_fetch']), {'url', 'maxLength'});
    expect(
      _toolPropertyNames(tools['search_memory']),
      containsAll(<String>{'query', 'max_results'}),
    );
    expect(
      _toolPropertyNames(tools['install_skill']),
      containsAll(<String>{'source_path', 'skill_content'}),
    );

    final allProperties = tools.values.expand(_toolPropertyNames).toSet();
    expect(allProperties, isNot(contains('file_path')));
    expect(allProperties, isNot(contains('offset')));
    expect(allProperties, isNot(contains('max_lines')));
    expect(allProperties, isNot(contains('command')));
    expect(allProperties, isNot(contains('input')));
    expect(allProperties, isNot(contains('q')));
    expect(allProperties, isNot(contains('max_length')));
  });

  test('every visible tool exposes auto-injected _purpose field', () async {
    final runtime = await _buildRuntime();
    for (final tool in runtime.modelVisibleTools) {
      final parameters = (tool.parameters).cast<String, dynamic>();
      final properties = (parameters['properties'] as Map?)
              ?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      expect(
        properties.keys,
        contains('_purpose'),
        reason: '${tool.name} 未注入 _purpose 字段',
      );
      final purposeSpec = (properties['_purpose'] as Map)
          .cast<String, dynamic>();
      expect(purposeSpec['type'], 'string');
      final required = (parameters['required'] as List?) ?? const <dynamic>[];
      expect(
        required,
        contains('_purpose'),
        reason: '${tool.name} 未把 _purpose 加入 required',
      );
    }
  });

  test('tool_search returns registered Codex tool metadata', () async {
    final runtime = await _buildRuntime();

    final result = await runtime.execute(
      _call('tool_search', <String, dynamic>{'query': 'patch', 'limit': 5}),
    );

    final body = _decode(result);
    expect(result.isError, isFalse);
    expect(body['ok'], isTrue);
    expect(
      body['tools'],
      contains(
        isA<Map>().having((tool) => tool['name'], 'name', 'apply_patch'),
      ),
    );
  });

  test(
    'dedicated file tools read, list, and search with PH01 schema',
    () async {
      final temp = await Directory.systemTemp.createTemp('codex_file_tools_');
      try {
        final nested = Directory('${temp.path}${Platform.pathSeparator}lib');
        await nested.create();
        final file = File('${nested.path}${Platform.pathSeparator}demo.txt');
        await file.writeAsString('alpha\nneedle here\nomega\n');
        final runtime = await _buildRuntime(cwd: temp.path);

        final readResult = await runtime.execute(
          _call('read_file', <String, dynamic>{
            'path': 'lib/demo.txt',
            'start_line': 2,
            'end_line': 2,
          }),
        );
        final readBody = _decode(readResult);
        expect(readResult.isError, isFalse);
        expect(readBody['content'], contains('needle here'));

        final listResult = await runtime.execute(
          _call('list_dir', <String, dynamic>{'dir_path': 'lib'}),
        );
        final listBody = _decode(listResult);
        expect(listResult.isError, isFalse);
        expect(
          listBody['entries'],
          contains(
            isA<Map>().having(
              (entry) => entry['relative_path'],
              'relative_path',
              'demo.txt',
            ),
          ),
        );

        final searchResult = await runtime.execute(
          _call('search_text', <String, dynamic>{
            'pattern': 'needle',
            'path': '.',
            'regex': false,
          }),
        );
        final searchBody = _decode(searchResult);
        expect(searchResult.isError, isFalse);
        expect(
          searchBody['matches'],
          contains(isA<Map>().having((match) => match['line'], 'line', 2)),
        );
      } finally {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      }
    },
  );

  test('request_permissions follows deny mode', () async {
    final runtime = await _buildRuntime(
      permissionPolicy: const CodexPermissionPolicy(
        mode: CodexPermissionMode.deny,
      ),
    );

    final result = await runtime.execute(
      _call('request_permissions', <String, dynamic>{
        'permissions': <String, dynamic>{
          'filesystem': <String, dynamic>{'write': true},
        },
      }),
    );

    final body = _decode(result);
    expect(result.isError, isTrue);
    expect(body['ok'], isFalse);
    expect(body['decision']['approved'], isFalse);
  });

  test('request_user_input delegates to client prompt callback', () async {
    CodexUserInputRequest? captured;
    final runtime = await _buildRuntime(
      userInputPrompt: (request) async {
        captured = request;
        return const CodexUserInputResponse(
          answers: <String, String>{'deploy_mode': 'private'},
        );
      },
    );

    final result = await runtime.execute(
      _call('request_user_input', <String, dynamic>{
        'questions': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'deploy_mode',
            'header': '部署',
            'question': 'DHT 是否公开？',
            'options': <Map<String, dynamic>>[
              <String, dynamic>{'label': 'private', 'description': '私有'},
              <String, dynamic>{'label': 'public', 'description': '公开'},
            ],
          },
        ],
      }),
    );

    final body = _decode(result);
    expect(result.isError, isFalse);
    expect(captured?.questions.single.id, 'deploy_mode');
    expect(body['response']['answers']['deploy_mode'], 'private');
  });

  test('Codex goal tools replace legacy todo model tool', () async {
    final runtime = await _buildRuntime(goalStore: CodexGoalStore());

    final createResult = await runtime.execute(
      _call('create_goal', <String, dynamic>{
        'objective': '完成 Codex Agent v2 工具迁移',
        'token_budget': 10000,
      }),
    );
    final created = _decode(createResult);
    expect(createResult.isError, isFalse);
    expect(created['goal']['status'], 'active');

    final getResult = await runtime.execute(
      _call('get_goal', <String, dynamic>{}),
    );
    final current = _decode(getResult);
    expect(getResult.isError, isFalse);
    expect(current['goal']['objective'], '完成 Codex Agent v2 工具迁移');

    final completeResult = await runtime.execute(
      _call('update_goal', <String, dynamic>{'status': 'complete'}),
    );
    final completed = _decode(completeResult);
    expect(completeResult.isError, isFalse);
    expect(completed['goal']['status'], 'complete');
  });

  test('user image blocks are converted to OpenAI multimodal content', () {
    final messages = runtimeMessagesToOpenAi([
      RuntimeMessage.userBlocks(const <RuntimeContentBlock>[
        RuntimeTextBlock('请看这张图'),
        RuntimeImageBlock(
          dataUrl:
              'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
          mimeType: 'image/png',
          label: 'demo.png',
        ),
      ]),
    ]);

    final content = messages.single['content'];
    expect(content, isA<List>());
    final parts = (content as List).cast<Map>();
    expect(parts.first['type'], 'text');
    expect(
      parts,
      contains(isA<Map>().having((part) => part['type'], 'type', 'image_url')),
    );
  });

  test(
    'view_image returns image data and queues visual follow-up context',
    () async {
      final temp = await Directory.systemTemp.createTemp('view_image_test_');
      try {
        final image = File('${temp.path}${Platform.pathSeparator}demo.png');
        await image.writeAsBytes(base64Decode(_onePixelPngBase64));
        final runtime = await _buildRuntime(cwd: temp.path);

        final result = await runtime.execute(
          _call('view_image', <String, dynamic>{
            'path': 'demo.png',
            'detail': 'original',
          }),
        );

        final body = _decode(result);
        expect(result.isError, isFalse);
        expect(body['image_url'], startsWith('data:image/png;base64,'));
        expect(result.followupMessages, hasLength(1));
        expect(
          result.followupMessages.single.content,
          contains(isA<RuntimeImageBlock>()),
        );
      } finally {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      }
    },
  );

  test('exec_command tty sessions can be continued with write_stdin', () async {
    final sessions = CodexProcessSessionStore();
    final runtime = await _buildRuntime(sessions: sessions);
    final command = Platform.isWindows
        ? r'cmd.exe /Q /K'
        : r'while IFS= read -r line; do echo "echo:$line"; [ "$line" = "exit" ] && break; done';
    final pingInput = Platform.isWindows ? 'echo echo:ping\r\n' : 'ping\n';
    final exitInput = Platform.isWindows ? 'exit\r\n' : 'exit\n';

    final startResult = await runtime.execute(
      _call('exec_command', <String, dynamic>{
        'cmd': command,
        'tty': true,
        'yield_time_ms': 100,
      }),
    );
    final startBody = _decode(startResult);
    expect(startResult.isError, isFalse);
    expect(startBody['session_id'], isA<int>());

    final writeResult = await runtime.execute(
      _call('write_stdin', <String, dynamic>{
        'session_id': startBody['session_id'],
        'chars': pingInput,
        'yield_time_ms': 1000,
      }),
    );
    final writeBody = _decode(writeResult);
    expect(writeResult.isError, isFalse);
    expect(writeBody['stdout'], contains('echo:ping'));

    await runtime.execute(
      _call('write_stdin', <String, dynamic>{
        'session_id': startBody['session_id'],
        'chars': exitInput,
        'yield_time_ms': 1000,
      }),
    );
    await sessions.dispose();
  });

  test('apply_patch supports add, update, and delete in cwd', () async {
    final temp = await Directory.systemTemp.createTemp(
      'codex_agent_runtime_test_',
    );
    try {
      final runtime = await _buildRuntime(cwd: temp.path);

      final addResult = await runtime.execute(
        _call('apply_patch', <String, dynamic>{
          'patch': '''
*** Begin Patch
*** Add File: notes/demo.txt
+hello
+world
*** End Patch
''',
        }),
      );
      expect(addResult.isError, isFalse);

      final file = File('${temp.path}${Platform.pathSeparator}notes/demo.txt');
      expect(await file.readAsString(), 'hello\nworld');

      final updateResult = await runtime.execute(
        _call('apply_patch', <String, dynamic>{
          'patch': '''
*** Begin Patch
*** Update File: notes/demo.txt
@@
-hello
+hi
 world
*** End Patch
''',
        }),
      );
      expect(updateResult.isError, isFalse);
      expect(await file.readAsString(), 'hi\nworld');

      final deleteResult = await runtime.execute(
        _call('apply_patch', <String, dynamic>{
          'patch': '''
*** Begin Patch
*** Delete File: notes/demo.txt
*** End Patch
''',
        }),
      );
      expect(deleteResult.isError, isFalse);
      expect(await file.exists(), isFalse);
    } finally {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    }
  });
}

Future<CodexAgentToolRuntime> _buildRuntime({
  String? cwd,
  CodexPermissionPolicy permissionPolicy = const CodexPermissionPolicy(
    mode: CodexPermissionMode.autoApprove,
  ),
  CodexUserInputPrompt? userInputPrompt,
  CodexProcessSessionStore? sessions,
  CodexGoalStore? goalStore,
}) {
  return CodexAgentToolRuntimeFactory.build(
    context: CodexToolContext(
      cwd: cwd,
      agentDir: null,
      activeAgentId: null,
      sessionPath: 'test-session',
      windowsOpsClient: WindowsOpsClient(),
      permissionPolicy: permissionPolicy,
      execCommandDefaultTimeoutSeconds: 30,
      userInputPrompt: userInputPrompt,
      goalStore: goalStore,
    ),
    windowsOpsCapabilities: const WindowsOpsCapabilities.unavailable(),
    processSessions: sessions,
  );
}

RuntimeToolCallBlock _call(String name, Map<String, dynamic> arguments) {
  return RuntimeToolCallBlock(
    id: 'call_$name',
    name: name,
    argumentsJson: jsonEncode(arguments),
    ended: true,
  );
}

Map<String, dynamic> _decode(RuntimeToolExecutionResult result) {
  return (jsonDecode(result.content) as Map).cast<String, dynamic>();
}

Set<String> _toolPropertyNames(Object? tool) {
  final parameters = ((tool as dynamic).parameters as Map)
      .cast<String, dynamic>();
  final properties =
      (parameters['properties'] as Map?)?.cast<String, dynamic>() ??
      const <String, dynamic>{};
  // 注册层会自动给每个工具的 schema 注入 `_purpose`（用于 UI 展示中文用途），
  // 这是全局行为而非某个工具特有的字段，断言时统一剥掉，避免污染等值检查。
  return properties.keys.where((k) => k != '_purpose').toSet();
}

const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=';
