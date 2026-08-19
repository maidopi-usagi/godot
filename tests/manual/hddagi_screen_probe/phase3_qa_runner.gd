extends "res://qa_runner.gd"

## Dedicated Phase 3 runtime smoke runner.
##
## The base QA script owns scene construction, image capture, measurements,
## logging, and atomic result publication. This subclass only adds the P3
## transport matrix so the frozen P0-P2 main scene remains unchanged.

const PHASE3_SUITE_NAME := "hddagi_screen_probe_phase3_spatial_restir_smoke"
const PHASE3_SCENARIO_NAME := "phase3_spatial"

const P3_SETTING_TEMPORAL := "rendering/global_illumination/hddagi/screen_probe_restir_temporal_guiding"
const P3_SETTING_SPATIAL := "rendering/global_illumination/hddagi/screen_probe_restir_spatial_guiding"
const P3_SETTING_CANDIDATES := "rendering/global_illumination/hddagi/screen_probe_restir_base_candidate_count"
const P3_SETTING_REFERENCE_MODE := "rendering/global_illumination/hddagi/screen_probe_reference_mode"
const P3_SETTING_DEBUG_COUNTERS := "rendering/global_illumination/hddagi/screen_probe_debug_counters"
const P3_SETTING_TEMPORAL_ROBUST := "rendering/global_illumination/hddagi/screen_probe_restir_temporal_robust_mode"
const P3_SETTING_TEMPORAL_M_CAP_MULTIPLIER := "rendering/global_illumination/hddagi/screen_probe_restir_temporal_m_cap_multiplier"
const P3_SETTING_TEMPORAL_MAXIMUM_AGE := "rendering/global_illumination/hddagi/screen_probe_restir_temporal_maximum_age"
const P3_SETTING_TEMPORAL_JACOBIAN_MAX := "rendering/global_illumination/hddagi/screen_probe_restir_temporal_jacobian_max"

const P3_CANDIDATE_COUNT := 1
const P3_TEMPORAL_M_CAP_MULTIPLIER := 20
const P3_TEMPORAL_MAXIMUM_AGE := 255
const P3_TEMPORAL_JACOBIAN_MAX := 20.0
const P3_SPATIAL_REUSE_RADIUS := 2
const P3_SPATIAL_NORMAL_THRESHOLD := 0.45
const P3_SPATIAL_DEPTH_TOLERANCE_MIN := 0.01
const P3_SPATIAL_DEPTH_TOLERANCE_SCALE := 0.01

const P3_CONFIGURATIONS := [
	{"label": "temporal_off", "temporal": false},
	{"label": "temporal_on", "temporal": true},
]


func _build_scene() -> void:
	super()
	_environment.dynamic_gi_screen_probe_restir_spatial_reuse_radius = P3_SPATIAL_REUSE_RADIUS
	_environment.dynamic_gi_screen_probe_restir_spatial_normal_threshold = P3_SPATIAL_NORMAL_THRESHOLD
	_environment.dynamic_gi_screen_probe_restir_spatial_depth_tolerance_min = P3_SPATIAL_DEPTH_TOLERANCE_MIN
	_environment.dynamic_gi_screen_probe_restir_spatial_depth_tolerance_scale = P3_SPATIAL_DEPTH_TOLERANCE_SCALE


func _phase3_settings_exist() -> bool:
	var required_settings := [
		P3_SETTING_TEMPORAL,
		P3_SETTING_SPATIAL,
		P3_SETTING_CANDIDATES,
		P3_SETTING_REFERENCE_MODE,
		P3_SETTING_DEBUG_COUNTERS,
		P3_SETTING_TEMPORAL_ROBUST,
		P3_SETTING_TEMPORAL_M_CAP_MULTIPLIER,
		P3_SETTING_TEMPORAL_MAXIMUM_AGE,
		P3_SETTING_TEMPORAL_JACOBIAN_MAX,
	]
	var all_exist := true
	for setting_name in required_settings:
		if not ProjectSettings.has_setting(setting_name):
			var message := "Phase 3 required ProjectSetting is missing: %s" % setting_name
			if not _errors.has(message):
				_errors.append(message)
			all_exist = false
	return all_exist


func _phase3_feature_state() -> Dictionary:
	return {
		"screen_probes": _environment.dynamic_gi_screen_probes_enabled,
		"reference_mode": bool(ProjectSettings.get_setting(P3_SETTING_REFERENCE_MODE, true)),
		"temporal_guiding": bool(ProjectSettings.get_setting(P3_SETTING_TEMPORAL, false)),
		"spatial_guiding": bool(ProjectSettings.get_setting(P3_SETTING_SPATIAL, false)),
		"candidate_count": int(ProjectSettings.get_setting(P3_SETTING_CANDIDATES, 0)),
		"temporal_robust_mode": bool(ProjectSettings.get_setting(P3_SETTING_TEMPORAL_ROBUST, true)),
		"temporal_m_cap_multiplier": int(ProjectSettings.get_setting(P3_SETTING_TEMPORAL_M_CAP_MULTIPLIER, 0)),
		"temporal_maximum_age": int(ProjectSettings.get_setting(P3_SETTING_TEMPORAL_MAXIMUM_AGE, 0)),
		"temporal_jacobian_max": float(ProjectSettings.get_setting(P3_SETTING_TEMPORAL_JACOBIAN_MAX, 0.0)),
	}


func _set_phase3_transport(temporal_enabled: bool) -> bool:
	if not _phase3_settings_exist():
		return false
	ProjectSettings.set_setting(P3_SETTING_REFERENCE_MODE, false)
	ProjectSettings.set_setting(P3_SETTING_TEMPORAL, temporal_enabled)
	ProjectSettings.set_setting(P3_SETTING_SPATIAL, true)
	ProjectSettings.set_setting(P3_SETTING_CANDIDATES, P3_CANDIDATE_COUNT)
	ProjectSettings.set_setting(P3_SETTING_TEMPORAL_ROBUST, false)
	ProjectSettings.set_setting(
			P3_SETTING_TEMPORAL_M_CAP_MULTIPLIER, P3_TEMPORAL_M_CAP_MULTIPLIER
	)
	ProjectSettings.set_setting(P3_SETTING_TEMPORAL_MAXIMUM_AGE, P3_TEMPORAL_MAXIMUM_AGE)
	ProjectSettings.set_setting(P3_SETTING_TEMPORAL_JACOBIAN_MAX, P3_TEMPORAL_JACOBIAN_MAX)
	var state := _phase3_feature_state()
	return (
			state.screen_probes
			and not state.reference_mode
			and state.temporal_guiding == temporal_enabled
			and state.spatial_guiding
			and state.candidate_count == P3_CANDIDATE_COUNT
			and not state.temporal_robust_mode
			and state.temporal_m_cap_multiplier == P3_TEMPORAL_M_CAP_MULTIPLIER
			and state.temporal_maximum_age == P3_TEMPORAL_MAXIMUM_AGE
			and is_equal_approx(state.temporal_jacobian_max, P3_TEMPORAL_JACOBIAN_MAX)
	)


func _phase3_configuration() -> Dictionary:
	return {
		"scenario": PHASE3_SCENARIO_NAME,
		"algorithm_mode": 4,
		"algorithm": "phase3_spatial_restir",
		"candidate_count": P3_CANDIDATE_COUNT,
		"spatial_candidate_count": 4,
		"spatial_reuse_radius": P3_SPATIAL_REUSE_RADIUS,
		"spatial_normal_threshold": P3_SPATIAL_NORMAL_THRESHOLD,
		"spatial_depth_tolerance_min": P3_SPATIAL_DEPTH_TOLERANCE_MIN,
		"spatial_depth_tolerance_scale": P3_SPATIAL_DEPTH_TOLERANCE_SCALE,
		"temporal_m_cap_multiplier": P3_TEMPORAL_M_CAP_MULTIPLIER,
		"temporal_maximum_age": P3_TEMPORAL_MAXIMUM_AGE,
		"temporal_jacobian_max": P3_TEMPORAL_JACOBIAN_MAX,
		"configurations": P3_CONFIGURATIONS.duplicate(true),
	}


func _make_result_header() -> Dictionary:
	var header := super()
	header.suite = PHASE3_SUITE_NAME
	header.phase3_configuration = _phase3_configuration()
	header.metric_contract.correctness_claim = (
			"portable P3 structural smoke only; no radiometric, variance, performance, or memory acceptance claim"
	)
	return header


func _capture_phase3_configuration(
		label: String,
		temporal_enabled: bool,
		warmup_frames: int,
		sample_frames: int
) -> Dictionary:
	var state_valid := _set_phase3_transport(temporal_enabled)
	_mark_segment("phase3_spatial/%s_warmup" % label)
	await _render_frames(warmup_frames)
	_mark_segment("phase3_spatial/%s_sample" % label)
	var images := await _capture_series(sample_frames)
	_sample_memory("phase3_spatial/%s" % label)
	var first_summary: Dictionary = _phase1_image_summary(images.front()) if not images.is_empty() else {}
	var last_summary: Dictionary = _phase1_image_summary(images.back()) if not images.is_empty() else {}
	var metrics := _measure_series(images)
	var state := _phase3_feature_state()
	return {
		"label": label,
		"temporal_enabled": temporal_enabled,
		"warmup_frames": warmup_frames,
		"sample_frames": sample_frames,
		"sample_segment": "phase3_spatial/%s_sample" % label,
		"state": state,
		"state_valid": state_valid,
		"first_frame": first_summary,
		"last_frame": last_summary,
		"metrics": metrics,
		"output_non_black_and_finite": (
				not first_summary.is_empty()
				and not last_summary.is_empty()
				and bool(first_summary.get("non_black", false))
				and bool(first_summary.get("finite", false))
				and bool(last_summary.get("non_black", false))
				and bool(last_summary.get("finite", false))
				and _phase2_metrics_are_finite(metrics)
		),
	}


func _run_phase3_spatial() -> Dictionary:
	_mark_segment("phase3_spatial/setup")
	var settings_exist := _phase3_settings_exist()
	_configure_phase2_regression_scene()
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
	var warmup_frames := maxi(_options.warmup_frames, 16)
	var sample_frames := maxi(_options.sample_frames, 8)
	var configurations: Array[Dictionary] = []
	for specification in P3_CONFIGURATIONS:
		configurations.append(
				await _capture_phase3_configuration(
						specification.label,
						bool(specification.temporal),
						warmup_frames,
						sample_frames
				)
		)

	# Give asynchronous stats readbacks submitted by the last sample segment
	# several rendered frames to deliver before the runner serializes its result.
	_mark_segment("phase3_spatial/post_sample_flush")
	await _render_frames(8)

	var all_states_valid := settings_exist and configurations.size() == P3_CONFIGURATIONS.size()
	var all_outputs_valid := not configurations.is_empty()
	var temporal_modes := {}
	for configuration in configurations:
		all_states_valid = all_states_valid and bool(configuration.state_valid)
		all_outputs_valid = all_outputs_valid and bool(configuration.output_non_black_and_finite)
		temporal_modes[str(configuration.temporal_enabled)] = true
	return {
		"description": "Portable Forward+ Vulkan P3 spatial runtime smoke across temporal reuse modes with the NRD/raw final path.",
		"configuration": _phase3_configuration(),
		"configurations": configurations,
		"checks": {
			"all_required_project_settings_exist": settings_exist,
			"both_configurations_executed": configurations.size() == 2,
			"all_configuration_states_valid": all_states_valid,
			"temporal_on_and_off_covered": temporal_modes.has("true") and temporal_modes.has("false"),
			"all_outputs_non_black_and_finite": all_outputs_valid,
		},
	}


func _run_suite() -> void:
	_result = _make_result_header()
	ProjectSettings.set_setting(P3_SETTING_DEBUG_COUNTERS, true)
	_mark_segment("phase3_spatial/suite_boot")
	if _options.scenario != PHASE3_SCENARIO_NAME:
		_errors.append(
				"Dedicated Phase 3 runner requires --scenario=%s, got '%s'."
				% [PHASE3_SCENARIO_NAME, _options.scenario]
		)
	else:
		_set_phase3_transport(false)
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
		await _render_frames(4)
		_sample_memory("phase3_spatial/after_boot")
		_result.scenarios[PHASE3_SCENARIO_NAME] = await _run_phase3_spatial()

	_restore_feature_settings()
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
	_result.debug_counters = _collect_debug_counters()
	_result.runtime_log = _collect_runtime_log_summary()
	if _result.runtime_log.error_count > 0:
		_errors.append(
				"Runtime log contains %d ERROR line(s); first observed in segment '%s'."
				% [_result.runtime_log.error_count, _result.runtime_log.first_error_segment]
		)
	_result.gpu_profile = _collect_gpu_profile()
	_result.memory = _make_memory_result()
	_validate_scenario_checks()
	_result.errors = _errors
	_result.warnings = _warnings
	_result.status = "failed" if not _errors.is_empty() else "completed"
	_result.completed_utc = Time.get_datetime_string_from_system(true, true)
	var wrote_result := _write_result()
	if not wrote_result:
		_result.status = "failed"
	get_tree().quit(1 if not _errors.is_empty() or not wrote_result else 0)
