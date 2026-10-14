<!-- Implement or refactor a Flecs ECS component, system, or query in C++ -->

Implement or refactor a Flecs ECS system or component in {{file}} for {{project}}.

Requirements:
1. Use modern C++20 idiomatic Flecs syntax (e.g. `world.system<...>()`, `world.component<...>()`, queries).
2. Iterate components efficiently through `it` (e.g. `it.field<T>(...)` or `it.each(...)`).
3. Maintain separation of concerns: components store pure data, systems implement behavior.
4. Follow the existing architecture and conventions in {{project}}.

{{region}}
