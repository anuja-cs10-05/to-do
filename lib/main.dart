import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:flutter_datetime_picker_plus/flutter_datetime_picker_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

// Initialize the notifications plugin
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
FlutterLocalNotificationsPlugin();

// Task model
class Task {
  String title;
  String description;
  DateTime dueDateTime;
  TaskPriority priority;
  bool isCompleted;
  int notificationId;

  Task({
    required this.title,
    required this.description,
    required this.dueDateTime,
    required this.priority,
    this.isCompleted = false,
    required this.notificationId,
  });

  // Convert Task to JSON
  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'description': description,
      'dueDateTime': dueDateTime.toIso8601String(),
      'priority': priority.index,
      'isCompleted': isCompleted,
      'notificationId': notificationId,
    };
  }

  // Create Task from JSON
  factory Task.fromJson(Map<String, dynamic> json) {
    return Task(
      title: json['title'],
      description: json['description'],
      dueDateTime: DateTime.parse(json['dueDateTime']),
      priority: TaskPriority.values[json['priority']],
      isCompleted: json['isCompleted'],
      notificationId: json['notificationId'],
    );
  }
}

// Priority enum
enum TaskPriority { low, medium, high }

// Task Controller using GetX
class TaskController extends GetxController {
  var tasks = <Task>[].obs;
  int _notificationIdCounter = 0;
  static const String _tasksKey = 'tasks';

  @override
  void onInit() {
    super.onInit();
    _initializeNotifications();
    tz.initializeTimeZones();
    _loadTasks();
  }

  // Initialize notifications
  Future<void> _initializeNotifications() async {
    // Request notification permission for Android 13+
    if (Platform.isAndroid) {
      final status = await Permission.notification.request();
      if (status.isDenied) {
        Get.snackbar('Permission Denied', 'Notification permission is required for reminders');
        return;
      }
    }

    const AndroidInitializationSettings initializationSettingsAndroid =
    AndroidInitializationSettings('notification_icon');
    const DarwinInitializationSettings initializationSettingsIOS =
    DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        if (response.payload != null) {
          Get.to(() => const TodoHomePage());
        }
      },
    );

    // Request iOS permissions
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );

    // Request exact alarm permission for Android
    if (Platform.isAndroid) {
      final androidImpl = flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.requestExactAlarmsPermission();
    }
  }

  // Load tasks from SharedPreferences
  Future<void> _loadTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final String? tasksString = prefs.getString(_tasksKey);
    if (tasksString != null) {
      final List<dynamic> tasksJson = jsonDecode(tasksString);
      tasks.assignAll(tasksJson.map((json) => Task.fromJson(json)).toList());
      _notificationIdCounter = tasks.isNotEmpty
          ? tasks.map((task) => task.notificationId).reduce((a, b) => a > b ? a : b) + 1
          : 0;
      for (var task in tasks) {
        if (!task.isCompleted) {
          await _scheduleNotification(task);
        }
      }
    }
  }

  // Save tasks to SharedPreferences
  Future<void> _saveTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final tasksJson = tasks.map((task) => task.toJson()).toList();
    await prefs.setString(_tasksKey, jsonEncode(tasksJson));
  }

  // Schedule a notification
  Future<void> _scheduleNotification(Task task) async {
    final reminderTime = task.dueDateTime.subtract(const Duration(minutes: 1)); // Changed to 1 minute for testing
    if (reminderTime.isBefore(DateTime.now())) return;

    final tzReminderTime = tz.TZDateTime.from(reminderTime, tz.local);

    final AndroidNotificationDetails androidPlatformChannelSpecifics =
    AndroidNotificationDetails(
      'todo_channel_id',
      'To-Do Reminders',
      channelDescription: 'Notifications for To-Do List tasks',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      enableVibration: true,
      playSound: true,
    );
    const DarwinNotificationDetails iOSPlatformChannelSpecifics = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    final NotificationDetails platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
      iOS: iOSPlatformChannelSpecifics,
    );

    await flutterLocalNotificationsPlugin.zonedSchedule(
      task.notificationId,
      'Task Reminder: ${task.title}',
      'Your task is due at ${DateFormat('dd MMM yyyy, hh:mm a').format(task.dueDateTime)}!',
      tzReminderTime,
      platformChannelSpecifics,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
      UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  // Cancel a notification
  Future<void> _cancelNotification(int notificationId) async {
    await flutterLocalNotificationsPlugin.cancel(notificationId);
  }

  void addTask(Task task) {
    tasks.add(task);
    if (!task.isCompleted) {
      _scheduleNotification(task);
    }
    _sortTasks();
    _saveTasks();
  }

  void updateTask(int index, Task task) {
    _cancelNotification(tasks[index].notificationId);
    tasks[index] = task;
    if (!task.isCompleted) {
      _scheduleNotification(task);
    }
    _sortTasks();
    _saveTasks();
  }

  void toggleTaskCompletion(int index) {
    tasks[index].isCompleted = !tasks[index].isCompleted;
    if (tasks[index].isCompleted) {
      _cancelNotification(tasks[index].notificationId);
    } else {
      _scheduleNotification(tasks[index]);
    }
    tasks.refresh();
    _saveTasks();
  }

  void deleteTask(int index) {
    _cancelNotification(tasks[index].notificationId);
    tasks.removeAt(index);
    _saveTasks();
  }

  void _sortTasks() {
    tasks.sort((a, b) {
      int dateComparison = a.dueDateTime.compareTo(b.dueDateTime);
      if (dateComparison != 0) {
        return dateComparison;
      }
      return b.priority.index.compareTo(a.priority.index);
    });
    tasks.refresh();
  }

  int generateNotificationId() {
    return _notificationIdCounter++;
  }
}

void main() {
  runApp(const TodoApp());
}

class TodoApp extends StatelessWidget {
  const TodoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'To-Do List',
      theme: ThemeData(
        primarySwatch: Colors.teal,
        scaffoldBackgroundColor: Colors.grey[100],
        textTheme: const TextTheme(
          headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.teal),
          titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          bodyMedium: TextStyle(fontSize: 14, color: Colors.black87),
        ),
      ),
      home: const TodoHomePage(),
    );
  }
}

class TodoHomePage extends StatelessWidget {
  const TodoHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final TaskController taskController = Get.put(TaskController());

    return Scaffold(
      appBar: AppBar(
        title: const Text('My To-Do List', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.teal,
        elevation: 2,
      ),
      body: Obx(
            () => taskController.tasks.isEmpty
            ? const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.task_alt, size: 80, color: Colors.teal),
              SizedBox(height: 16),
              Text(
                'No tasks yet!\nAdd a task to get started.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, color: Colors.grey),
              ),
            ],
          ),
        )
            : Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text(
                'Tasks sorted by due date (earliest first), then priority (High to Low)',
                style: TextStyle(fontSize: 14, color: Colors.black54),
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: taskController.tasks.length,
                itemBuilder: (context, index) {
                  final task = taskController.tasks[index];
                  return TaskCard(index: index, task: task);
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Get.to(() => const AddTaskPage()),
        backgroundColor: Colors.teal,
        child: const Icon(Icons.add, color: Colors.white),
        heroTag: 'addTask',
      ),
    );
  }
}

class TaskCard extends StatelessWidget {
  final int index;
  final Task task;

  const TaskCard({super.key, required this.index, required this.task});

  @override
  Widget build(BuildContext context) {
    final TaskController taskController = Get.find();
    return GestureDetector(
      onTap: () => Get.to(() => EditTaskPage(index: index)),
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: index == 0
              ? const BorderSide(color: Colors.teal, width: 2)
              : BorderSide.none,
        ),
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: index == 0 ? Colors.teal : Colors.grey,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Checkbox(
                value: task.isCompleted,
                onChanged: (value) => taskController.toggleTaskCompletion(index),
                activeColor: Colors.teal,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        decoration: task.isCompleted ? TextDecoration.lineThrough : null,
                        color: task.isCompleted ? Colors.grey : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      task.description,
                      style: const TextStyle(fontSize: 14, color: Colors.black54),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Due: ${DateFormat('dd MMM yyyy, hh:mm a').format(task.dueDateTime)}',
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 8),
                    PriorityChip(priority: task.priority),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit, color: Colors.teal),
                    onPressed: () => Get.to(() => EditTaskPage(index: index)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => taskController.deleteTask(index),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PriorityChip extends StatelessWidget {
  final TaskPriority priority;

  const PriorityChip({super.key, required this.priority});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (priority) {
      case TaskPriority.high:
        color = Colors.red;
        break;
      case TaskPriority.medium:
        color = Colors.orange;
        break;
      case TaskPriority.low:
        color = Colors.green;
        break;
    }
    return Chip(
      label: Text(
        StringExtension(priority.name).capitalize!,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
      backgroundColor: color,
      padding: const EdgeInsets.symmetric(horizontal: 8),
    );
  }
}

class AddTaskPage extends StatelessWidget {
  const AddTaskPage({super.key});

  @override
  Widget build(BuildContext context) {
    final TaskController taskController = Get.find();
    final titleController = TextEditingController();
    final descriptionController = TextEditingController();
    var selectedDateTime = DateTime.now().obs;
    var selectedPriority = TaskPriority.low.obs;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add New Task', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.teal,
        elevation: 2,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Task Title', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: titleController,
                decoration: InputDecoration(
                  hintText: 'Enter task title',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Description', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: descriptionController,
                decoration: InputDecoration(
                  hintText: 'Enter task description',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              const Text('Due Date & Time', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Obx(
                    () => ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  title: Text(
                    DateFormat('dd MMM yyyy, hh:mm a').format(selectedDateTime.value),
                    style: const TextStyle(fontSize: 14),
                  ),
                  trailing: const Icon(Icons.calendar_today, color: Colors.teal),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: Colors.teal),
                  ),
                  onTap: () {
                    DatePicker.showDateTimePicker(
                      context,
                      showTitleActions: true,
                      minTime: DateTime.now(),
                      onConfirm: (date) {
                        selectedDateTime.value = date;
                      },
                      currentTime: selectedDateTime.value,
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              const Text('Priority', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Obx(
                    () => DropdownButtonFormField<TaskPriority>(
                  value: selectedPriority.value,
                  items: TaskPriority.values
                      .map((priority) => DropdownMenuItem(
                    value: priority,
                    child: Text(StringExtension(priority.name).capitalize!),
                  ))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      selectedPriority.value = value;
                    }
                  },
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Center(
                child: ElevatedButton(
                  onPressed: () {
                    if (titleController.text.isNotEmpty && descriptionController.text.isNotEmpty) {
                      taskController.addTask(Task(
                        title: titleController.text,
                        description: descriptionController.text,
                        dueDateTime: selectedDateTime.value,
                        priority: selectedPriority.value,
                        notificationId: taskController.generateNotificationId(),
                      ));
                      Get.back();
                    } else {
                      Get.snackbar('Error', 'Please fill all fields');
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Add Task', style: TextStyle(fontSize: 16, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class EditTaskPage extends StatelessWidget {
  final int index;

  const EditTaskPage({super.key, required this.index});

  @override
  Widget build(BuildContext context) {
    final TaskController taskController = Get.find();
    final task = taskController.tasks[index];
    final titleController = TextEditingController(text: task.title);
    final descriptionController = TextEditingController(text: task.description);
    var selectedDateTime = task.dueDateTime.obs;
    var selectedPriority = task.priority.obs;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Task', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.teal,
        elevation: 2,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Task Title', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: titleController,
                decoration: InputDecoration(
                  hintText: 'Enter task title',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Description', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: descriptionController,
                decoration: InputDecoration(
                  hintText: 'Enter task description',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              const Text('Due Date & Time', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Obx(
                    () => ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  title: Text(
                    DateFormat('dd MMM yyyy, hh:mm a').format(selectedDateTime.value),
                    style: const TextStyle(fontSize: 14),
                  ),
                  trailing: const Icon(Icons.calendar_today, color: Colors.teal),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: Colors.teal),
                  ),
                  onTap: () {
                    DatePicker.showDateTimePicker(
                      context,
                      showTitleActions: true,
                      minTime: DateTime.now(),
                      onConfirm: (date) {
                        selectedDateTime.value = date;
                      },
                      currentTime: selectedDateTime.value,
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              const Text('Priority', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Obx(
                    () => DropdownButtonFormField<TaskPriority>(
                  value: selectedPriority.value,
                  items: TaskPriority.values
                      .map((priority) => DropdownMenuItem(
                    value: priority,
                    child: Text(StringExtension(priority.name).capitalize!),
                  ))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      selectedPriority.value = value;
                    }
                  },
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Center(
                child: ElevatedButton(
                  onPressed: () {
                    if (titleController.text.isNotEmpty && descriptionController.text.isNotEmpty) {
                      taskController.updateTask(
                        index,
                        Task(
                          title: titleController.text,
                          description: descriptionController.text,
                          dueDateTime: selectedDateTime.value,
                          priority: selectedPriority.value,
                          isCompleted: task.isCompleted,
                          notificationId: task.notificationId,
                        ),
                      );
                      Get.back();
                    } else {
                      Get.snackbar('Error', 'Please fill all fields');
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Update Task', style: TextStyle(fontSize: 16, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Extension for capitalizing strings
extension StringExtension on String {
  String? get capitalize {
    if (isEmpty) return null;
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}