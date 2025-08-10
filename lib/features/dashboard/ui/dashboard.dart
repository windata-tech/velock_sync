import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/features/dashboard/state/dashboard_provider.dart';

class Dashboard extends HookConsumerWidget {
  const Dashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scrollController = useScrollController();

    final syncTasks = ref.watch(syncTasksProvider);

    return PlatformScaffold(
      appBar: PlatformAppBar(
        title: Text('Dashboard'),
        material: (_, __) => MaterialAppBarData(
          backgroundColor: const Color(0xFF2d2d2d),
          titleTextStyle: const TextStyle(color: Color(0xFFe7e8eb)),
        ),
        cupertino: (_, __) => CupertinoNavigationBarData(
          backgroundColor: const Color(0xFF2d2d2d),
          // middleTextStyle: const TextStyle(color: Color(0xFFe7e8eb)),
        ),
      ),
      body: syncTasks.when(
        data: (value) => value.isEmpty
            ? const Center(child: Text('No sync tasks found'))
            : ListView.separated(
                itemBuilder: (context, index) {
                  final task = value[index];
                  return ListTile(
                    title: Text(task.name),
                    subtitle: Text('Status: ${task.status}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: () {
                        ref.read(syncTasksProvider.notifier).removeSyncTask(task);
                      },
                    ),
                  );
                },
                separatorBuilder: (context, index) {
                  return Divider();
                },
                itemCount: value.length,
              ),
        error: (e, s) {
          loge(e, stackTrace: s);
          return Text('Error! e=$e');
        },
        loading: () => const CircularProgressIndicator(),
      ),
    );
  }
}
