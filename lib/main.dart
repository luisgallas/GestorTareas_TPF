// Importaciones básicas de Dart y Flutter necesarias para el app.
import 'dart:io'; // Para detectar plataforma (Windows/Linux/Mac/iOS/Android).
import 'package:flutter/material.dart'; // Widgets y Material Design.
import 'package:path/path.dart'; // join() para rutas multiplataforma.
import 'package:path_provider/path_provider.dart'; // getApplicationDocumentsDirectory.
import 'package:provider/provider.dart'; // State management (Provider).
import 'package:sqflite_common_ffi/sqflite_ffi.dart'; // SQLite para escritorio con ffi.
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; // Notificaciones locales.
import 'package:google_fonts/google_fonts.dart'; // Fuentes Google (Poppins).
import 'package:timezone/data/latest_all.dart' as tz; // Inicializar zonas horarias.
import 'package:timezone/timezone.dart' as tz; // TZDateTime para programar notificaciones.

// =====================================================
//                       MAIN
// =====================================================
void main() async {
  // Asegura que los bindings de Flutter estén inicializados (necesario cuando usamos async en main).
  WidgetsFlutterBinding.ensureInitialized();

  // Inicialización específica para plataformas de escritorio (usa sqflite_ffi).
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    // Inicializa la implementación FFI de sqflite para escritorio.
    sqfliteFfiInit();
    // Redirige la fábrica de bases de datos a la FFI (útil en desktop).
    databaseFactory = databaseFactoryFfi;
  }

  // Inicializa el sistema de notificaciones (configuración).
  await NotificationsHelper.init();

  // Abre/crea la base de datos de tareas.
  final db = await TasksDb.open();

  // Ejecuta la app envolviendo el árbol con ChangeNotifierProvider
  // para que TaskList esté disponible en todo el widget tree.
  runApp(
    ChangeNotifierProvider(
      create: (_) => TaskList(db),
      child: const MyApp(),
    ),
  );
}

// =====================================================
//               NOTIFICACIONES LOCALES
// =====================================================
// Helper para configurar y programar notificaciones locales.
class NotificationsHelper {
  // Plugin para notificaciones.
  static final FlutterLocalNotificationsPlugin _plugin =
  FlutterLocalNotificationsPlugin();

  // Inicializa el plugin: canales, permisos, zonas horarias.
  static Future<void> init() async {
    // Inicializa zonas horarias para convertir DateTime a TZDateTime.
    tz.initializeTimeZones();

    // Icono para Android (usa el mipmap ic_launcher por defecto).
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

    // Configuración iOS (Darwin).
    const iosSettings = DarwinInitializationSettings();

    // Configuración combinada.
    const initSettings =
    InitializationSettings(android: androidSettings, iOS: iosSettings);

    // Inicializa el plugin con la configuración.
    await _plugin.initialize(initSettings);
  }

  // Programa una notificación 10 minutos antes del reminder de la tarea (si existe).
  static Future<void> schedule(Task task) async {
    // Si no tiene recordatorio, no hace nada.
    if (task.reminder == null) return;

    // Queremos notificar 10 minutos antes.
    final scheduledTime = task.reminder!.subtract(const Duration(minutes: 10));

    // Detalles del canal/notification en Android.
    const androidDetails = AndroidNotificationDetails(
      'task_channel', // id del canal
      'Tareas', // nombre del canal visible al usuario
      channelDescription: 'Recordatorios de tareas', // descripción del canal
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
    );

    // Detalles combinados (solo android configurado aquí; iOS usaría otros campos).
    const notificationDetails = NotificationDetails(android: androidDetails);

    // Programar la notificación en la zona horaria local a la fecha indicada.
    await _plugin.zonedSchedule(
      task.id!, // id de la notificación (usamos id de la tarea)
      'Recordatorio de Tarea', // título
      '${task.title}\n${task.description}', // cuerpo (título + descripción)
      tz.TZDateTime.from(scheduledTime, tz.local), // fecha programada en tz.local
      notificationDetails, // detalles de la notificación
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
      UILocalNotificationDateInterpretation.absoluteTime,
    );
  }
}

// =====================================================
//                       MODELO
// =====================================================
// Modelo que representa una tarea en la app.
class Task {
  final int? id; // id en la BD (nullable porque al insertar aún no tiene id)
  final String title; // título obligatorio
  final String description; // descripción opcional
  final bool done; // si está completada
  final DateTime? reminder; // fecha/hora del recordatorio (nullable)

  Task({
    this.id,
    required this.title,
    this.description = '',
    this.done = false,
    this.reminder,
  });

  // Crea una copia con campos opcionalmente reemplazados (útil para toggle done).
  Task copyWith({
    int? id,
    String? title,
    String? description,
    bool? done,
    DateTime? reminder,
  }) {
    return Task(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      done: done ?? this.done,
      reminder: reminder ?? this.reminder,
    );
  }

  // Convierte el modelo a un Map para guardar en SQLite.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'done': done ? 1 : 0, // almacenar booleano como entero 0/1
      'reminder': reminder?.toIso8601String(), // almacenar fecha como ISO string
    };
  }

  // Crea un Task a partir de un Map leído de la BD.
  factory Task.fromMap(Map<String, dynamic> map) {
    return Task(
      id: map['id'],
      title: map['title'],
      description: map['description'] ?? '',
      done: map['done'] == 1,
      reminder:
      map['reminder'] != null ? DateTime.parse(map['reminder']) : null,
    );
  }
}

// =====================================================
//                      BASE DE DATOS
// =====================================================
// Clase que encapsula la lógica de acceso a SQLite.
class TasksDb {
  final Database db;
  TasksDb._(this.db);

  // Abre la base de datos (crea si no existe) y aplica migraciones.
  static Future<TasksDb> open() async {
    // Obtiene directorio de documentos de la app (multiplataforma).
    Directory dir = await getApplicationDocumentsDirectory();
    // Construye ruta: <documents>/tasks.db
    String path = join(dir.path, 'tasks.db');

    // Abre la DB usando la databaseFactory (redirigida a FFI en desktop).
    Database db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        // Función que crea las tablas si la base no existe.
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE tasks(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              title TEXT,
              description TEXT,
              done INTEGER,
              reminder TEXT
            )
          ''');
        },
        // Migraciones: si la versión antigua es menor que 2, agrega columnas.
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            // Nota: si ya existían esas columnas, estas instrucciones fallarían.
            // Esta lógica asume que versiones previas no tenían description/reminder.
            await db.execute(
                'ALTER TABLE tasks ADD COLUMN description TEXT');
            await db.execute('ALTER TABLE tasks ADD COLUMN reminder TEXT');
          }
        },
      ),
    );
    return TasksDb._(db);
  }

  // Obtiene todas las tareas como lista de Task.
  Future<List<Task>> getTasks() async {
    final maps = await db.query('tasks');
    return maps.map((e) => Task.fromMap(e)).toList();
  }

  // Inserta una tarea y devuelve el id asignado por la BD.
  Future<int> insertTask(Task task) async =>
      await db.insert('tasks', task.toMap());

  // Actualiza una tarea existente en la BD.
  Future<int> updateTask(Task task) async => await db.update(
    'tasks',
    task.toMap(),
    where: 'id = ?',
    whereArgs: [task.id],
  );

  // Elimina una tarea por id.
  Future<int> deleteTask(int id) async =>
      await db.delete('tasks', where: 'id = ?', whereArgs: [id]);

  // Borra todas las tareas completadas.
  Future<void> clearCompleted() async =>
      await db.delete('tasks', where: 'done = ?', whereArgs: [1]);
}

// =====================================================
//                 PROVIDER: TaskList
// =====================================================
// ChangeNotifier que mantiene la lista de tareas y expone operaciones.
class TaskList extends ChangeNotifier {
  final TasksDb db; // instancia de acceso a BD.
  final List<Task> _items = []; // almacenamiento interno

  TaskList(this.db) {
    // Al crear el provider cargamos las tareas de la BD.
    _loadTasks();
  }

  // Getter inmutable para los items.
  List<Task> get items => List.unmodifiable(_items);
  int get total => _items.length;
  int get completed => _items.where((t) => t.done).length;
  int get pending => total - completed;

  // Carga tareas desde BD al _items y notifica listeners.
  Future<void> _loadTasks() async {
    final list = await db.getTasks();
    _items
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  // Añade una nueva tarea: valida title, inserta en BD, notifica y programa recordatorio.
  Future<void> add(String title, String description, DateTime? reminder) async {
    if (title.trim().isEmpty) return; // evita títulos vacíos
    // Inserta en BD y obtiene id.
    final id = await db.insertTask(
        Task(title: title, description: description, reminder: reminder));
    // Crea un Task con el id retornado.
    final task =
    Task(id: id, title: title, description: description, reminder: reminder);
    _items.add(task); // agrega a la lista local
    notifyListeners(); // actualiza UI
    await NotificationsHelper.schedule(task); // programa notificación si aplica
  }

  // Alterna el estado done de una tarea y guarda en BD.
  Future<void> toggle(Task t) async {
    final newTask = t.copyWith(done: !t.done);
    await db.updateTask(newTask);
    final i = _items.indexWhere((e) => e.id == t.id);
    if (i != -1) _items[i] = newTask;
    notifyListeners();
  }

  // Elimina una tarea (BD + lista local).
  Future<void> remove(Task t) async {
    if (t.id == null) return;
    await db.deleteTask(t.id!);
    _items.removeWhere((e) => e.id == t.id);
    notifyListeners();
  }

  // Borra todas las completadas (BD + lista local).
  Future<void> clearCompleted() async {
    await db.clearCompleted();
    _items.removeWhere((t) => t.done);
    notifyListeners();
  }
}

// =====================================================
//                       APP (MyApp)
// =====================================================
// StatefulWidget para manejar el modo claro/oscuro.
class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // Modo de tema por defecto.
  ThemeMode _themeMode = ThemeMode.light;

  // Cambia el themeMode y reconstruye.
  void toggleTheme() {
    setState(() {
      _themeMode =
      _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Aquí cambiamos el title que se usa como título de la ventana/taskbar.
      title: 'TPF_Gestor_Tareas', // <- Cambiado para mostrar TPF_Gestor_Tareas en la esquina (window title)
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      // Tema claro
      theme: ThemeData(
        brightness: Brightness.light,
        colorSchemeSeed: Colors.indigo,
        textTheme: GoogleFonts.poppinsTextTheme(),
      ),
      // Tema oscuro
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.deepPurple,
        textTheme: GoogleFonts.poppinsTextTheme()
            .apply(bodyColor: Colors.white, displayColor: Colors.white),
      ),
      // Página principal
      home: HomePage(onToggleTheme: toggleTheme),
    );
  }
}

// =====================================================
//                    HOME PAGE
// =====================================================
class HomePage extends StatelessWidget {
  final VoidCallback onToggleTheme;
  const HomePage({super.key, required this.onToggleTheme});

  // Muestra selectores de fecha y hora y devuelve un DateTime combinado.
  Future<DateTime?> pickDateTime(BuildContext context) async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime(2100),
    );
    if (date == null) return null;
    final time =
    await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  @override
  Widget build(BuildContext context) {
    // Obtiene el provider con la lista de tareas.
    final list = context.watch<TaskList>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      // Barra superior de la app.
      appBar: AppBar(
        title: const Text('Mis Tareas'), // Título visible dentro de la app
        actions: [
          // Botón para alternar tema
          IconButton(icon: const Icon(Icons.brightness_6), onPressed: onToggleTheme),
          // Muestra botón de limpiar completadas solo si hay completadas (>0)
          if (list.completed > 0)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: list.clearCompleted,
            ),
        ],
      ),
      body: Column(
        children: [
          // ---------- ESTADÍSTICAS ----------
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _statCard("Pendientes", list.pending, Colors.orange, isDark),
                _statCard("Completadas", list.completed, Colors.green, isDark),
                _statCard("Total", list.total, Colors.teal, isDark),
              ],
            ),
          ),
          // ---------- LISTA DE TAREAS ----------
          Expanded(
            child: list.items.isEmpty
            // Texto cuando no hay tareas
                ? const Center(child: Text('No hay tareas aún'))
            // Lista de tarjetas con tareas
                : ListView.builder(
              itemCount: list.items.length,
              itemBuilder: (_, i) {
                final t = list.items[i];
                return Card(
                  margin:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ListTile(
                    leading: Checkbox(
                      value: t.done,
                      onChanged: (_) => list.toggle(t),
                    ),
                    title: Text(
                      t.title,
                      style: TextStyle(
                        decoration:
                        t.done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    subtitle: Text(
                      [
                        if (t.description.isNotEmpty) t.description,
                        if (t.reminder != null)
                          '📅 ${t.reminder!.day}/${t.reminder!.month} ${t.reminder!.hour}:${t.reminder!.minute.toString().padLeft(2, '0')}'
                      ].join('\n'),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => list.remove(t),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      // Botón flotante para crear nueva tarea (extendido con texto).
      floatingActionButton: FloatingActionButton.extended(
        label: const Text('Nueva tarea'),
        icon: const Icon(Icons.add),
        onPressed: () async {
          // Primero pedimos la fecha/hora del reminder; si cancela no se sigue.
          final reminder = await pickDateTime(context);
          if (reminder == null) return;
          // Abrimos un diálogo para capturar título y descripción.
          final data = await showDialog<Map<String, String>>(
            context: context,
            builder: (_) => const TaskDialog(),
          );
          // Si usuario guardó, agregamos la tarea al provider.
          if (data != null) {
            context
                .read<TaskList>()
                .add(data['title']!, data['description']!, reminder);
          }
        },
      ),
    );
  }

  // Widget auxiliar para mostrar tarjetas de estadísticas.
  Widget _statCard(String label, int value, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? color.withOpacity(0.25) : color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(label,
              style: TextStyle(
                  color: isDark ? Colors.white : Colors.black,
                  fontWeight: FontWeight.bold)),
          Text("$value",
              style: TextStyle(
                  fontSize: 18,
                  color: isDark ? Colors.white : Colors.black,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// =====================================================
//                DIALOGO NUEVA TAREA
// =====================================================
class TaskDialog extends StatefulWidget {
  const TaskDialog({super.key});

  @override
  State<TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends State<TaskDialog> {
  // Controladores para los TextField del diálogo.
  final titleC = TextEditingController();
  final descC = TextEditingController();

  @override
  void dispose() {
    // Liberar controladores al cerrar el widget para evitar memory leaks.
    titleC.dispose();
    descC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nueva tarea'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
              controller: titleC,
              decoration: const InputDecoration(labelText: 'Título')),
          TextField(
              controller: descC,
              decoration: const InputDecoration(labelText: 'Descripción')),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: () {
            if (titleC.text.trim().isEmpty) return; // validar título
            Navigator.pop(context, {
              'title': titleC.text,
              'description': descC.text,
            });
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
