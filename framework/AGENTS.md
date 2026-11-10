# Agent Guidelines: Game Stage Prototype Framework

This document provides the necessary context, coding standards, and operational commands for agents working on the Game Stage Prototype framework. The goal of this project is to create a bulletproof, modular framework for rapidly iterating on mobile game prototypes using Godot 4.x.

## 🛠 Operational Commands

### Running the Game
Godot projects are typically run via the editor, but for CLI-based agents:
- **Run Project**: `godot --path .`
- **Run Headless (for tests/tools)**: `godot --headless --path .`

### Testing
This project utilizes **GUT (Godot Unit Testing)** for automated tests.
The `-s` entry point is `gut_cmdln.gd` (a SceneTree wrapper). Do NOT use
`gut_cli.gd` directly with `-s` — it is a Node, not a main loop.
- **Run All Tests**: `godot --headless --path . -s res://addons/gut/gut_cmdln.gd -gdir=res://tests -gexit`
- **Run Single Test File**: `godot --headless --path . -s res://addons/gut/gut_cmdln.gd -gtest=res://tests/path/to/test.gd -gexit`

### Linting & Formatting
- **Linting**: Use the built-in Godot GDScript linter. Ensure "Warnings" are treated as errors in the editor settings.
- **Formatting**: Follow the official GDScript style guide. Use 4-space indentation (tabs are acceptable if consistent).

---

## 🎨 Code Style Guidelines

### GDScript Standards
We strictly adhere to the Godot 4.x GDScript style guide with additional constraints for prototype stability.

#### 1. Naming Conventions
- **Classes**: `PascalCase` (e.g., `ScreenManager`, `AudioManager`).
- **Variables**: `snake_case` (e.g., `current_screen`, `is_active`).
- **Functions**: `snake_case` (e.g., `calculate_score()`, `update_ui()`).
- **Constants**: `SCREAMING_SNAKE_CASE` (e.g., `MAX_PLAYER_SPEED`, `DEFAULT_SAVE_PATH`).
- **Private Variables**: Prefix with an underscore (e.g., `_internal_state`).
- **Signals**: `snake_case` and usually in the present tense (e.g., `score_changed`, `game_started`).

#### 2. Static Typing
Static typing is **mandatory** for all declarations to ensure codebase stability and performance.
- **Variables**: `var score: int = 0`
- **Functions**: `func add_points(amount: int) -> void:`
- **Array/Dict**: `var players: Array[Player] = []` or `var config: Dictionary = {}`

#### 3. Imports and Dependencies
- Use `class_name` for all primary scripts to enable global access without needing `load()` or `preload()`.
- Minimize hard-coded paths. Use a central `Paths` or `Config` singleton for directory references.
- Use `preload()` for assets needed at initialization; use `load()` for dynamic loading.

#### 4. Error Handling
- Avoid silent failures. Use `push_error()` for critical issues and `push_warning()` for non-critical ones.
- Use `assert()` during development to catch invariant violations.
- For asynchronous operations, always implement a timeout or a "fail" callback.

---

## 📂 Project Structure

To maintain modularity, follow this directory layout:
- `res://scenes/`: All `.tscn` files, organized by screen/feature.
- `res://scripts/`: Logic files. Match the scene structure (e.g., `res://scripts/ui/home_screen.gd`).
- `res://assets/`: Textures, audio, and fonts.
- `res://core/`: Framework-level systems (SaveSystem, Analytics, etc.).
- `res://tests/`: GUT test suites.
- `res://resources/`: Custom `.tres` files and data definitions.

---

## ⚙️ Framework Implementation Principles

### Modularity
Systems must be decoupled. Use an **Event Bus** (Global Signal Bus) for communication between disparate systems (e.g., `Game` notifying `Analytics`).

### Save Persistence
All save data must be serialized to JSON or binary via the `SaveSystem` core module. Do not use `OS.set_config_file` for player progress.

### UI Consistency
UI elements must inherit from a base `UIElement` or use a centralized `Theme` resource. Hard-coding colors or margins is forbidden.

### Performance
- Use `_physics_process` for physics-related logic and `_process` for visual updates.
- Minimize the use of `get_node()` in `_process`; cache node references in `_ready()` using `@onready`.
