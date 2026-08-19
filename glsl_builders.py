"""Functions used to generate source files during build time"""

from __future__ import annotations

import os.path
import re

from methods import generated_wrapper, print_error, to_raw_cstring


_INCLUDE_PATTERN = re.compile(r'^\s*#\s*include\s*[<"]([^">]+)[">]')
# Build-only directive for optional SDK headers. It is removed when no external include roots are configured.
_EXTERNAL_INCLUDE_PATTERN = re.compile(r'^\s*#\s*include_external\s*[<"]([^">]+)[">]')


def _get_shader_source_root(env) -> str:
    try:
        return env.Dir("#").abspath
    except AttributeError:
        return os.getcwd()


def _get_external_shader_include_paths(env) -> list[str]:
    source_root = _get_shader_source_root(env)
    include_paths = []
    for include_path in env.get("GLSL_INCLUDE_PATHS", []):
        include_path = os.path.expandvars(os.path.expanduser(str(include_path)))
        if not os.path.isabs(include_path):
            include_path = os.path.join(source_root, include_path)
        include_path = os.path.normpath(os.path.abspath(include_path))
        if include_path not in include_paths:
            include_paths.append(include_path)

    return include_paths


def _get_shader_include_paths(env) -> list[str]:
    """Return normalized local and external roots used by the GLSL header builders."""
    return [_get_shader_source_root(env)] + _get_external_shader_include_paths(env)


def _get_include_name(line: str) -> str | None:
    match = _INCLUDE_PATTERN.match(line)
    return match.group(1) if match else None


def _get_external_include_name(line: str) -> str | None:
    match = _EXTERNAL_INCLUDE_PATTERN.match(line)
    return match.group(1) if match else None


def _get_include_directive(line: str) -> tuple[str, bool] | None:
    include_name = _get_external_include_name(line)
    if include_name is not None:
        return include_name, True

    include_name = _get_include_name(line)
    if include_name is not None:
        return include_name, False

    return None


def _resolve_shader_include(
    filename: str,
    include_name: str,
    include_paths: list[str],
    directive: str = "#include",
    include_current_directory: bool = True,
    confine_to_include_paths: bool = False,
) -> str:
    if os.path.isabs(include_name):
        candidates = [include_name]
    else:
        candidates = []
        if include_current_directory:
            candidates.append(os.path.join(os.path.dirname(filename), include_name))
        candidates.extend(os.path.join(include_path, include_name) for include_path in include_paths)

    searched_paths = []
    allowed_roots = [os.path.normcase(os.path.realpath(path)) for path in include_paths]
    for candidate in candidates:
        candidate = os.path.normpath(os.path.abspath(candidate))
        if candidate in searched_paths:
            continue
        searched_paths.append(candidate)
        if confine_to_include_paths:
            candidate_identity = os.path.normcase(os.path.realpath(candidate))
            try:
                if not any(os.path.commonpath([candidate_identity, root]) == root for root in allowed_roots):
                    continue
            except ValueError:
                continue
        if os.path.isfile(candidate):
            return candidate

    searched = "\n\t".join(searched_paths)
    raise FileNotFoundError(
        f'In shader file "{filename}": {directive} "{include_name}" was not found. Searched:\n\t{searched}'
    )


def _collect_shader_dependencies(
    filename: str,
    include_paths: list[str],
    external_includes_enabled: bool,
    dependencies: list[str],
    visited: set[str],
) -> None:
    filename = os.path.normpath(os.path.abspath(filename))
    identity = os.path.normcase(os.path.realpath(filename))
    if identity in visited:
        return
    visited.add(identity)

    with open(filename, "r", encoding="utf-8") as shader_file:
        for line in shader_file:
            include_directive = _get_include_directive(line)
            if include_directive is None:
                continue
            include_name, is_external = include_directive
            if is_external and not external_includes_enabled:
                continue

            directive = "#include_external" if is_external else "#include"
            included_file = _resolve_shader_include(
                filename,
                include_name,
                include_paths[1:] if is_external else include_paths,
                directive,
                include_current_directory=not is_external,
                confine_to_include_paths=is_external,
            )
            dependencies.append(included_file)
            _collect_shader_dependencies(
                included_file, include_paths, external_includes_enabled, dependencies, visited
            )


def glsl_headers_emitter(target, source, env):
    """Track local and external shader includes as SCons dependencies."""
    external_include_paths = _get_external_shader_include_paths(env)
    include_paths = [_get_shader_source_root(env)] + external_include_paths
    external_includes_enabled = bool(env.get("GLSL_EXTERNAL_INCLUDES_ENABLED", False))
    dependencies = []
    visited = set()
    try:
        for src in source:
            _collect_shader_dependencies(str(src), include_paths, external_includes_enabled, dependencies, visited)
    except FileNotFoundError as error:
        print_error(str(error))
        raise

    if dependencies:
        env.Depends(target, dependencies)
    env.Depends(target, env.Value(os.pathsep.join(external_include_paths)))
    env.Depends(target, env.Value(str(int(external_includes_enabled))))
    return target, source


class RDHeaderStruct:
    def __init__(self):
        self.vertex_lines = []
        self.fragment_lines = []
        self.compute_lines = []
        self.raygen_lines = []
        self.any_hit_lines = []
        self.closest_hit_lines = []
        self.miss_lines = []
        self.intersection_lines = []

        self.vertex_included_files = []
        self.fragment_included_files = []
        self.compute_included_files = []
        self.raygen_included_files = []
        self.any_hit_included_files = []
        self.closest_hit_included_files = []
        self.miss_included_files = []
        self.intersection_included_files = []

        self.reading = ""
        self.line_offset = 0
        self.vertex_offset = 0
        self.fragment_offset = 0
        self.compute_offset = 0
        self.raygen_offset = 0
        self.any_hit_offset = 0
        self.closest_hit_offset = 0
        self.miss_offset = 0
        self.intersection_offset = 0


def include_file_in_rd_header(
    filename: str,
    header_data: RDHeaderStruct,
    depth: int,
    include_paths: list[str],
    external_includes_enabled: bool,
) -> RDHeaderStruct:
    filename = os.path.normpath(os.path.abspath(filename))
    with open(filename, "r", encoding="utf-8") as fs:
        line = fs.readline()

        while line:
            index = line.find("//")
            if index != -1:
                line = line[:index]

            if line.find("#[vertex]") != -1:
                header_data.reading = "vertex"
                line = fs.readline()
                header_data.line_offset += 1
                header_data.vertex_offset = header_data.line_offset
                continue

            if line.find("#[fragment]") != -1:
                header_data.reading = "fragment"
                line = fs.readline()
                header_data.line_offset += 1
                header_data.fragment_offset = header_data.line_offset
                continue

            if line.find("#[compute]") != -1:
                header_data.reading = "compute"
                line = fs.readline()
                header_data.line_offset += 1
                header_data.compute_offset = header_data.line_offset
                continue

            if line.find("#[raygen]") != -1:
                header_data.reading = "raygen"
                line = fs.readline()
                header_data.line_offset += 1
                header_data.raygen_offset = header_data.line_offset
                continue

            if line.find("#[any_hit]") != -1:
                header_data.reading = "any_hit"
                line = fs.readline()
                header_data.line_offset += 1
                header_data.any_hit_offset = header_data.line_offset
                continue

            if line.find("#[closest_hit]") != -1:
                header_data.reading = "closest_hit"
                line = fs.readline()
                header_data.line_offset += 1
                header_data.closest_hit_offset = header_data.line_offset
                continue

            if line.find("#[miss]") != -1:
                header_data.reading = "miss"
                line = fs.readline()
                header_data.line_offset += 1
                header_data.miss_offset = header_data.line_offset
                continue

            if line.find("#[intersection]") != -1:
                header_data.reading = "intersection"
                line = fs.readline()
                header_data.line_offset += 1
                header_data.intersection_offset = header_data.line_offset
                continue

            include_directive = _get_include_directive(line)
            while include_directive is not None:
                include_name, is_external = include_directive
                if is_external and not external_includes_enabled:
                    line = fs.readline()
                    include_directive = _get_include_directive(line)
                    continue

                directive = "#include_external" if is_external else "#include"
                included_file = _resolve_shader_include(
                    filename,
                    include_name,
                    include_paths[1:] if is_external else include_paths,
                    directive,
                    include_current_directory=not is_external,
                    confine_to_include_paths=is_external,
                )

                if included_file not in header_data.vertex_included_files and header_data.reading == "vertex":
                    header_data.vertex_included_files += [included_file]
                    include_file_in_rd_header(
                        included_file, header_data, depth + 1, include_paths, external_includes_enabled
                    )
                elif included_file not in header_data.fragment_included_files and header_data.reading == "fragment":
                    header_data.fragment_included_files += [included_file]
                    include_file_in_rd_header(
                        included_file, header_data, depth + 1, include_paths, external_includes_enabled
                    )
                elif included_file not in header_data.compute_included_files and header_data.reading == "compute":
                    header_data.compute_included_files += [included_file]
                    include_file_in_rd_header(
                        included_file, header_data, depth + 1, include_paths, external_includes_enabled
                    )
                elif included_file not in header_data.raygen_included_files and header_data.reading == "raygen":
                    header_data.raygen_included_files += [included_file]
                    include_file_in_rd_header(
                        included_file, header_data, depth + 1, include_paths, external_includes_enabled
                    )
                elif included_file not in header_data.any_hit_included_files and header_data.reading == "any_hit":
                    header_data.any_hit_included_files += [included_file]
                    include_file_in_rd_header(
                        included_file, header_data, depth + 1, include_paths, external_includes_enabled
                    )
                elif (
                    included_file not in header_data.closest_hit_included_files and header_data.reading == "closest_hit"
                ):
                    header_data.closest_hit_included_files += [included_file]
                    include_file_in_rd_header(
                        included_file, header_data, depth + 1, include_paths, external_includes_enabled
                    )
                elif included_file not in header_data.miss_included_files and header_data.reading == "miss":
                    header_data.miss_included_files += [included_file]
                    include_file_in_rd_header(
                        included_file, header_data, depth + 1, include_paths, external_includes_enabled
                    )
                elif (
                    included_file not in header_data.intersection_included_files
                    and header_data.reading == "intersection"
                ):
                    header_data.intersection_included_files += [included_file]
                    include_file_in_rd_header(
                        included_file, header_data, depth + 1, include_paths, external_includes_enabled
                    )

                line = fs.readline()
                include_directive = _get_include_directive(line)

            line = line.replace("\r", "").replace("\n", "")

            if header_data.reading == "vertex":
                header_data.vertex_lines += [line]
            if header_data.reading == "fragment":
                header_data.fragment_lines += [line]
            if header_data.reading == "compute":
                header_data.compute_lines += [line]
            if header_data.reading == "raygen":
                header_data.raygen_lines += [line]
            if header_data.reading == "any_hit":
                header_data.any_hit_lines += [line]
            if header_data.reading == "closest_hit":
                header_data.closest_hit_lines += [line]
            if header_data.reading == "miss":
                header_data.miss_lines += [line]
            if header_data.reading == "intersection":
                header_data.intersection_lines += [line]

            line = fs.readline()
            header_data.line_offset += 1

    return header_data


def build_rd_header_lines_for_raytracing_stage(lines, stage: str):
    if lines:
        return f"""\
		static const char _{stage}_code[] = {{
{to_raw_cstring(lines)}
		}};
"""
    else:
        return f"""\
		static const char *_{stage}_code = nullptr;
"""


def build_rd_header(
    filename: str,
    shader: str,
    include_paths: list[str] | None = None,
    external_includes_enabled: bool = False,
) -> None:
    include_file_in_rd_header(
        shader,
        header_data := RDHeaderStruct(),
        0,
        include_paths or [os.getcwd()],
        external_includes_enabled,
    )
    class_name = os.path.basename(shader).replace(".glsl", "").title().replace("_", "").replace(".", "") + "ShaderRD"

    with generated_wrapper(filename) as file:
        file.write(f"""\
#include "servers/rendering/renderer_rd/shader_rd.h"

class {class_name} : public ShaderRD {{
public:
	{class_name}() {{
""")

        if (
            header_data.raygen_lines
            or header_data.any_hit_lines
            or header_data.closest_hit_lines
            or header_data.miss_lines
            or header_data.intersection_lines
        ):
            file.write(build_rd_header_lines_for_raytracing_stage(header_data.raygen_lines, "raygen"))
            file.write(build_rd_header_lines_for_raytracing_stage(header_data.any_hit_lines, "any_hit"))
            file.write(build_rd_header_lines_for_raytracing_stage(header_data.closest_hit_lines, "closest_hit"))
            file.write(build_rd_header_lines_for_raytracing_stage(header_data.miss_lines, "miss"))
            file.write(build_rd_header_lines_for_raytracing_stage(header_data.intersection_lines, "intersection"))
            file.write(f"""\
		setup_raytracing(_raygen_code, _any_hit_code, _closest_hit_code, _miss_code, _intersection_code, "{class_name}");
""")
        elif header_data.compute_lines:
            file.write(f"""\
		static const char *_vertex_code = nullptr;
		static const char *_fragment_code = nullptr;
		static const char _compute_code[] = {{
{to_raw_cstring(header_data.compute_lines)}
		}};
		setup(_vertex_code, _fragment_code, _compute_code, "{class_name}");
""")
        else:
            file.write(f"""\
		static const char _vertex_code[] = {{
{to_raw_cstring(header_data.vertex_lines)}
		}};
		static const char _fragment_code[] = {{
{to_raw_cstring(header_data.fragment_lines)}
		}};
		static const char *_compute_code = nullptr;
		setup(_vertex_code, _fragment_code, _compute_code, "{class_name}");
""")

        file.write("""\
	}
};
""")


def build_rd_headers(target, source, env):
    env.NoCache(target)
    include_paths = _get_shader_include_paths(env)
    external_includes_enabled = bool(env.get("GLSL_EXTERNAL_INCLUDES_ENABLED", False))
    for src in source:
        build_rd_header(f"{src}.gen.h", str(src), include_paths, external_includes_enabled)


class RAWHeaderStruct:
    def __init__(self):
        self.code = ""


def include_file_in_raw_header(
    filename: str,
    header_data: RAWHeaderStruct,
    depth: int,
    include_paths: list[str],
    external_includes_enabled: bool,
) -> None:
    filename = os.path.normpath(os.path.abspath(filename))
    with open(filename, "r", encoding="utf-8") as fs:
        line = fs.readline()

        while line:
            include_directive = _get_include_directive(line)
            while include_directive is not None:
                include_name, is_external = include_directive
                if is_external and not external_includes_enabled:
                    line = fs.readline()
                    include_directive = _get_include_directive(line)
                    continue

                directive = "#include_external" if is_external else "#include"
                included_file = _resolve_shader_include(
                    filename,
                    include_name,
                    include_paths[1:] if is_external else include_paths,
                    directive,
                    include_current_directory=not is_external,
                    confine_to_include_paths=is_external,
                )
                include_file_in_raw_header(
                    included_file, header_data, depth + 1, include_paths, external_includes_enabled
                )

                line = fs.readline()
                include_directive = _get_include_directive(line)

            header_data.code += line
            line = fs.readline()


def build_raw_header(
    filename: str,
    shader: str,
    include_paths: list[str] | None = None,
    external_includes_enabled: bool = False,
) -> None:
    header_data = RAWHeaderStruct()
    include_file_in_raw_header(
        shader, header_data, 0, include_paths or [os.getcwd()], external_includes_enabled
    )

    with generated_wrapper(filename) as file:
        file.write(f"""\
static const char {os.path.basename(shader).replace(".glsl", "_shader_glsl")}[] = {{
{to_raw_cstring(header_data.code)}
}};
""")


def build_raw_headers(target, source, env):
    env.NoCache(target)
    include_paths = _get_shader_include_paths(env)
    external_includes_enabled = bool(env.get("GLSL_EXTERNAL_INCLUDES_ENABLED", False))
    for src in source:
        build_raw_header(f"{src}.gen.h", str(src), include_paths, external_includes_enabled)
