/// `Result<S, E>` sealed class —— 全 Dart 项目里所有可失败操作都返回这个，
/// 强制调用方 exhaustive switch 处理错误。规避 BUG-4（频道异常静默失败）。
sealed class Result<S, E> {
  const Result();

  bool get isOk => this is Ok<S, E>;
  bool get isErr => this is Err<S, E>;
}

class Ok<S, E> extends Result<S, E> {
  final S value;
  const Ok(this.value);
}

class Err<S, E> extends Result<S, E> {
  final E error;
  const Err(this.error);
}
