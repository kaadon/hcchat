/// ID 解析：Go 后端雪花 ID 以字符串输出（避免 JS 精度丢失），native/H5 统一兼容
int intOf(dynamic v) =>
    v is String ? (int.tryParse(v) ?? 0) : ((v as num?)?.toInt() ?? 0);
