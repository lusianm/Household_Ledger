import 'package:flutter/material.dart';
import '../domain/value.dart';
import '../sync/drive_sync.dart';
import 'common.dart';

class DriveFolderPicker extends StatefulWidget {
  final DriveTransport drive;
  final String email;
  const DriveFolderPicker({
    super.key,
    required this.drive,
    required this.email,
  });
  @override
  State<DriveFolderPicker> createState() => _DriveFolderPickerState();
}

class _DriveFolderPickerState extends State<DriveFolderPicker> {
  final path = <Json>[
    {'id': 'root', 'name': '내 드라이브'},
  ];
  List<Json> folders = [];
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.drive.folders(path.last['id'] as String);
      if (mounted) setState(() => folders = result);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> create() async {
    final result = await prompt(context, '새 동기화 폴더', [
      const PromptField('name', '폴더 이름', initial: '차곡 가계부'),
    ]);
    if (result == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final folder = await widget.drive.createFolder(
        path.last['id'] as String,
        result['name'] as String,
      );
      if (!mounted) return;
      path.add(folder);
      await load();
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '$e';
        });
      }
    }
  }

  Future<void> select() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final selected = await widget.drive.folder(path.last['id'] as String);
      if (mounted) Navigator.pop(context, selected);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('동기화 폴더 선택'),
    content: SizedBox(
      width: 560,
      height: MediaQuery.sizeOf(context).height * .48,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.email, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          Text(
            path.map((f) => f['name']).join(' / '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          Wrap(
            spacing: 8,
            children: [
              if (path.length > 1)
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () {
                          path.removeLast();
                          load();
                        },
                  icon: const Icon(Icons.arrow_upward),
                  label: const Text('상위 폴더'),
                ),
              TextButton.icon(
                onPressed: busy ? null : create,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('새 폴더'),
              ),
            ],
          ),
          Expanded(
            child: busy
                ? const Center(child: CircularProgressIndicator())
                : error != null
                ? SingleChildScrollView(
                    child: Column(
                      children: [
                        Text(error!),
                        TextButton(
                          onPressed: load,
                          child: const Text('다시 불러오기'),
                        ),
                      ],
                    ),
                  )
                : folders.isEmpty
                ? const Center(
                    child: Text(
                      '하위 폴더가 없어요.\n이 폴더를 선택하거나 새로 만들 수 있어요.',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    itemCount: folders.length,
                    itemBuilder: (context, index) {
                      final folder = folders[index];
                      return ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(folder['name'] as String),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          path.add(folder);
                          load();
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: busy || error != null || path.length == 1 ? null : select,
        child: const Text('이 폴더 선택'),
      ),
    ],
  );
}
