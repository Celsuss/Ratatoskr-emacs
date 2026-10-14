<!-- Implement or update a Raylib rendering routine or Dear ImGui debug overlay -->

Implement or update the Raylib rendering or Dear ImGui debug interface in {{file}} for {{project}}.

Requirements:
1. Follow Raylib's frame lifecycle (`BeginDrawing()`, `ClearBackground()`, camera passes, `EndDrawing()`).
2. If Dear ImGui is used (e.g. `rlImGui`), ensure `rlImGuiBegin()` and `rlImGuiEnd()` enclose all ImGui calls.
3. Manage textures, models, shaders, and window resources cleanly without memory or GPU resource leaks.
4. Follow existing conventions in {{project}}.

{{region}}
