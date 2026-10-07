import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A reusable instruction block the user can switch on/off. Enabled skills are
/// appended to the system prompt of every chat.
class Skill {
  final String id;
  String name;
  String instructions;
  bool enabled;
  Skill(this.id, this.name, this.instructions, {this.enabled = true});

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'instructions': instructions, 'enabled': enabled};

  factory Skill.fromJson(Map<String, dynamic> j) => Skill(
      j['id'].toString(), '${j['name']}', '${j['instructions']}',
      enabled: j['enabled'] != false);
}

class SkillStore extends ChangeNotifier {
  static const _key = 'skills_v1';
  List<Skill> skills = [];
  late SharedPreferences _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    final raw = _p.getString(_key);
    if (raw == null) {
      skills = [
        Skill('code-review', 'Code reviewer',
            'When shown code, review it for bugs, security issues and clarity before suggesting changes.',
            enabled: false),
        Skill('concise', 'Concise answers',
            'Keep answers short and direct. Skip preambles and avoid repeating the question.',
            enabled: false),
      ];
      await _save();
      return;
    }
    try {
      skills = [
        for (final j in jsonDecode(raw) as List) Skill.fromJson(j as Map<String, dynamic>)
      ];
    } catch (_) {
      skills = [];
    }
  }

  Future<void> _save() async {
    await _p.setString(_key, jsonEncode([for (final s in skills) s.toJson()]));
    notifyListeners();
  }

  Future<void> add(String name, String instructions) {
    skills.add(Skill(DateTime.now().microsecondsSinceEpoch.toString(), name, instructions));
    return _save();
  }

  Future<void> update(Skill s, String name, String instructions) {
    s.name = name;
    s.instructions = instructions;
    return _save();
  }

  Future<void> setEnabled(Skill s, bool v) {
    s.enabled = v;
    return _save();
  }

  Future<void> remove(Skill s) {
    skills.remove(s);
    return _save();
  }

  /// Text to append to the system prompt (empty when no skill is on).
  String get promptAddendum {
    final on = skills.where((s) => s.enabled && s.instructions.trim().isNotEmpty);
    if (on.isEmpty) return '';
    return '\n\nActive skills:\n${[for (final s in on) '- ${s.name}: ${s.instructions.trim()}'].join('\n')}';
  }
}
