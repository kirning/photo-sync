import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/remote_path.dart';
import '../../models/storage_config.dart';
import '../../state/app_state.dart';
import '../widgets/dialogs.dart';

class StorageFormScreen extends StatefulWidget {
  const StorageFormScreen({super.key, this.config});

  final StorageConfig? config;

  bool get isEditing => config != null;

  @override
  State<StorageFormScreen> createState() => _StorageFormScreenState();
}

class _StorageFormScreenState extends State<StorageFormScreen> {
  static const _uuid = Uuid();

  late StorageType _type = widget.config?.type ?? StorageType.webdav;
  late final TextEditingController _name =
      TextEditingController(text: widget.config?.name ?? '');
  final Map<String, TextEditingController> _controllers = {};
  final Set<String> _visibleSecrets = {};
  final Map<String, bool> _switches = {};
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final field in _fieldSpecs(_type)) {
      _controllers[field.key] =
          TextEditingController(text: widget.config?.field(field.key, field.initial) ?? '');
    }
    for (final field in _switchSpecs(_type)) {
      _switches[field.key] = widget.config?.boolField(field.key, field.initial) ?? field.initial;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _changeType(StorageType type) {
    if (type == _type) return;
    setState(() {
      _type = type;
      _controllers.clear();
      _switches.clear();
      for (final field in _fieldSpecs(type)) {
        _controllers[field.key] = TextEditingController(text: field.initial);
      }
      for (final field in _switchSpecs(type)) {
        _switches[field.key] = field.initial;
      }
      if (_name.text.trim().isEmpty) _name.text = type.label;
    });
  }

  StorageConfig _build() {
    final fields = <String, dynamic>{};
    for (final entry in _controllers.entries) {
      fields[entry.key] = entry.value.text.trim();
    }
    for (final entry in _switches.entries) {
      fields[entry.key] = entry.value;
    }
    return StorageConfig(
      id: widget.config?.id ?? _uuid.v4(),
      name: _name.text.trim().isEmpty ? _type.label : _name.text.trim(),
      type: _type,
      fields: fields,
      enabled: widget.config?.enabled ?? true,
      createdAt: widget.config?.createdAt ?? DateTime.now(),
    );
  }

  Future<void> _save({bool testAfter = false}) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final state = context.read<AppState>();
    final config = _build();
    await state.saveStorage(config);
    String? error;
    if (testAfter) {
      error = await state.testStorage(config);
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      showMessage(context, '保存成功，但连接失败：$error', error: true);
      return;
    }
    showMessage(context, testAfter ? '连接成功，已保存' : '已保存');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fields = _fieldSpecs(_type);
    final switches = _switchSpecs(_type);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? '编辑存储服务' : '添加存储服务'),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => _save(),
            child: const Text('保存'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (!widget.isEditing) ...[
              Text('服务类型', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<StorageType>(
                segments: [
                  for (final type in StorageType.values)
                    ButtonSegment(
                      value: type,
                      icon: Icon(type.icon, size: 18),
                      label: Text(type.label),
                    ),
                ],
                selected: {_type},
                onSelectionChanged: (value) => _changeType(value.first),
              ),
              const SizedBox(height: 8),
              Text(
                _type.description,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
            ] else
              Row(
                children: [
                  Icon(_type.icon, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text('${_type.label} · ${_type.description}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '例如：家里的 NAS',
              ),
              textInputAction: TextInputAction.next,
              validator: (value) =>
                  (value == null || value.trim().isEmpty) ? '请填写名称' : null,
            ),
            for (final field in fields) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _controllers[field.key],
                decoration: InputDecoration(
                  labelText: field.label,
                  hintText: field.hint,
                  helperText: field.helper,
                  suffixIcon: field.secret
                      ? IconButton(
                          tooltip: _visibleSecrets.contains(field.key) ? '隐藏' : '显示',
                          onPressed: () => setState(() {
                            if (!_visibleSecrets.remove(field.key)) {
                              _visibleSecrets.add(field.key);
                            }
                          }),
                          icon: Icon(
                            _visibleSecrets.contains(field.key)
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                        )
                      : null,
                ),
                obscureText:
                    field.secret && !_visibleSecrets.contains(field.key),
                keyboardType: field.keyboard,
                textInputAction: TextInputAction.next,
                validator: (value) {
                  if (!field.required) return null;
                  if (value == null || value.trim().isEmpty) {
                    return '请填写${field.label}';
                  }
                  return null;
                },
              ),
            ],
            if (switches.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('高级选项', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              for (final field in switches)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(field.label),
                  subtitle: field.helper == null ? null : Text(field.helper!),
                  value: _switches[field.key] ?? field.initial,
                  onChanged: (value) => setState(() => _switches[field.key] = value),
                ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : () => _save(testAfter: true),
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('保存并测试连接'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '远端目录：照片会按 ${RemotePathUtil.defaultFolderTemplate} 的结构存放，'
              '其中 {album} 是相册名。留空表示直接放在根目录。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldSpec {
  const _FieldSpec({
    required this.key,
    required this.label,
    this.hint,
    this.helper,
    this.initial = '',
    this.secret = false,
    this.required = false,
    this.keyboard,
  });

  final String key;
  final String label;
  final String? hint;
  final String? helper;
  final String initial;
  final bool secret;
  final bool required;
  final TextInputType? keyboard;
}

class _SwitchSpec {
  const _SwitchSpec({
    required this.key,
    required this.label,
    this.helper,
    this.initial = false,
  });

  final String key;
  final String label;
  final String? helper;
  final bool initial;
}

List<_FieldSpec> _fieldSpecs(StorageType type) {
  switch (type) {
    case StorageType.webdav:
      return const [
        _FieldSpec(
          key: 'url',
          label: '服务器地址',
          hint: 'https://dav.example.com/dav',
          required: true,
          keyboard: TextInputType.url,
        ),
        _FieldSpec(key: 'username', label: '用户名'),
        _FieldSpec(key: 'password', label: '密码', secret: true),
        _FieldSpec(
          key: 'root',
          label: '远端目录',
          hint: 'PhotoSync',
          helper: '留空表示根目录',
        ),
      ];
    case StorageType.smb:
      return const [
        _FieldSpec(
          key: 'host',
          label: '主机地址',
          hint: '192.168.1.10',
          required: true,
        ),
        _FieldSpec(
          key: 'share',
          label: '共享名称',
          hint: 'photo',
          required: true,
          helper: 'Windows 共享或 NAS 上共享文件夹的名称',
        ),
        _FieldSpec(key: 'domain', label: '域（可选）', hint: 'WORKGROUP'),
        _FieldSpec(key: 'username', label: '用户名'),
        _FieldSpec(key: 'password', label: '密码', secret: true),
        _FieldSpec(
          key: 'root',
          label: '远端目录',
          hint: 'PhotoSync',
          helper: '留空表示共享根目录',
        ),
      ];
    case StorageType.s3:
      return const [
        _FieldSpec(
          key: 'endpoint',
          label: 'Endpoint',
          hint: 'https://s3.us-east-1.amazonaws.com',
          required: true,
          keyboard: TextInputType.url,
          helper: 'MinIO 填 http://IP:9000',
        ),
        _FieldSpec(
          key: 'region',
          label: 'Region',
          initial: 'us-east-1',
          required: true,
        ),
        _FieldSpec(key: 'bucket', label: 'Bucket', required: true),
        _FieldSpec(key: 'accessKey', label: 'Access Key', required: true),
        _FieldSpec(
          key: 'secretKey',
          label: 'Secret Key',
          secret: true,
          required: true,
        ),
        _FieldSpec(key: 'sessionToken', label: 'Session Token（可选）', secret: true),
        _FieldSpec(
          key: 'root',
          label: '对象前缀',
          hint: 'PhotoSync',
          helper: '留空表示放在 Bucket 根目录',
        ),
      ];
  }
}

List<_SwitchSpec> _switchSpecs(StorageType type) {
  switch (type) {
    case StorageType.webdav:
      return const [
        _SwitchSpec(
          key: 'allowBadCert',
          label: '允许自签名证书',
          helper: '群晖等设备使用自签名 HTTPS 证书时打开',
        ),
      ];
    case StorageType.smb:
      return const [
        _SwitchSpec(
          key: 'forceSmb1',
          label: '强制使用 SMB1',
          helper: '仅老旧设备需要，默认使用 SMB2/3',
        ),
      ];
    case StorageType.s3:
      return const [
        _SwitchSpec(
          key: 'pathStyle',
          label: 'Path-style 访问',
          helper: 'MinIO、部分自建服务需要打开',
          initial: true,
        ),
        _SwitchSpec(
          key: 'allowBadCert',
          label: '允许自签名证书',
          helper: '自建服务使用自签名 HTTPS 时打开',
        ),
      ];
  }
}
