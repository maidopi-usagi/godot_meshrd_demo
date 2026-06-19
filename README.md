# MeshRD Metaball Demo

This project demonstrates MeshRD's current indirect procedural GPU mesh workflow:

1. Create RenderingDevice vertex, attribute, index, and indirect buffers.
2. Pass those caller-owned buffers to `MeshRD.add_surface()`.
3. Fill the buffers from compute shaders and draw through the indirect command buffer.

Godot PR: https://github.com/godotengine/godot/pull/117836
