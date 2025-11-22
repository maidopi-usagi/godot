#include "register_types.h"

#include "core/object/class_db.h"
#include "rive_viewer.h"

void initialize_rive_module(ModuleInitializationLevel p_level) {
    if (p_level == MODULE_INITIALIZATION_LEVEL_SCENE) {
        // Register the viewer type
        ClassDB::register_class<RiveViewer>();
    }
}

void uninitialize_rive_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}
