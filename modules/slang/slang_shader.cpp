/**************************************************************************/
/*  slang_shader.cpp                                                            */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "slang_shader.h"
#include "core/string/print_string.h"
#include "thirdparty/slang/slang.h"
#include "core/io/file_access.h"
#include "slang_project_settings.h"
#include "core/io/json.h"

using Slang::ComPtr;

ComPtr<slang::IGlobalSession> SlangShader::_global_session;

Slang::ComPtr<slang::IGlobalSession> SlangShader::_get_global_session() const {
	if (_global_session == nullptr) {
        slang::createGlobalSession(_global_session.writeRef());
        SlangProjectSettings::read_settings();
        print_line("Slang global session created.");
    }
    return _global_session;
}

void SlangShader::set_code(const String &p_code) {
	code = p_code;
    _compile_shader();
    emit_changed();
}

String SlangShader::get_code() const {
	return code;
}

void SlangShader::_compile_shader() {
    auto slangGlobalSession = _get_global_session();

    slang::SessionDesc sessionDesc = {};
    slang::TargetDesc targetDesc = {};
    targetDesc.format = SLANG_SPIRV;
    targetDesc.profile = slangGlobalSession->findProfile("spirv_1_5");
    targetDesc.flags = 0;

    Vector<std::string> search_paths_storage;
    Vector<const char*> search_paths_utf8;
    for (int i = 0; i < SlangProjectSettings::include_paths.size(); i++) {
        search_paths_storage.push_back(SlangProjectSettings::include_paths[i].utf8().get_data());
        search_paths_utf8.push_back(search_paths_storage[i].c_str());
    }
    sessionDesc.searchPaths = search_paths_utf8.ptr();
    sessionDesc.searchPathCount = search_paths_utf8.size();

    sessionDesc.targets = &targetDesc;
    sessionDesc.targetCount = 1;

    Vector<slang::CompilerOptionEntry> options;
    options.push_back(
        {slang::CompilerOptionName::EmitSpirvDirectly,
         {slang::CompilerOptionValueKind::Int, 1, 0, nullptr, nullptr}});
    sessionDesc.compilerOptionEntries = options.ptrw();
    sessionDesc.compilerOptionEntryCount = options.size();

    ComPtr<slang::ISession> session;
    ERR_FAIL_COND(slangGlobalSession->createSession(sessionDesc, session.writeRef()));

    slang::IModule* slangModule = nullptr;
    {
        ComPtr<slang::IBlob> diagnosticBlob;
        slangModule = session->loadModuleFromSourceString(
            get_name().utf8().ptr(), 
            get_path().utf8().ptr(), 
            code.utf8().ptr(), 
            diagnosticBlob.writeRef()
        );
        ERR_FAIL_COND_MSG(slangModule == nullptr, static_cast<const char*>(diagnosticBlob->getBufferPointer()));
    }

    ComPtr<slang::IEntryPoint> entryPoint;
    slangModule->findEntryPointByName("computeMain", entryPoint.writeRef());

    Vector<slang::IComponentType*> componentTypes;
    componentTypes.push_back(slangModule);
    componentTypes.push_back(entryPoint);

    ComPtr<slang::IComponentType> composedProgram;
    {
        ComPtr<slang::IBlob> diagnosticsBlob;
        SlangResult result = session->createCompositeComponentType(
            componentTypes.ptrw(),
            componentTypes.size(),
            composedProgram.writeRef(),
            diagnosticsBlob.writeRef());
        ERR_FAIL_COND(result == SLANG_FAIL);
    }

    auto programLayout = composedProgram->getLayout();
    ERR_FAIL_COND(programLayout == nullptr);
    auto entriesCount = programLayout->getEntryPointCount();
    auto entry = programLayout->getEntryPointByIndex(0);

    ComPtr<slang::IBlob> jsonBlob;
    {
        programLayout->toJson(jsonBlob.writeRef());
    }
    ERR_FAIL_COND(jsonBlob == nullptr);

    auto jsonContent = static_cast<const char*>(jsonBlob->getBufferPointer());
    auto jsonStr = String::utf8(jsonContent, jsonBlob->getBufferSize());
    jsonStr = jsonStr.replace("\\", "\\\\");
    reflection_info = JSON::parse_string(jsonStr);
    print_line(reflection_info);

    // auto paramsCount = programLayout->getParameterCount();
    // for (size_t i = 0; i < paramsCount; i++)
    // {
    //     auto param = programLayout->getParameterByIndex(i);
    //     auto paramVar = param->getVariable();
    //     auto paramType = param->getType();
    //     auto paramUserAttrCount = paramVar->getUserAttributeCount();
    //     for (size_t j = 0; j < paramUserAttrCount; j++) {
    //         auto userAttr = paramVar->getUserAttributeByIndex(j);
    //         auto userAttrName = userAttr->getName();
    //         int intVal;
    //         float floatVal;
    //         size_t bufSize = 0;
    //         for (size_t k = 0; k < userAttr->getArgumentCount(); k++)
    //         {
    //             if (SLANG_SUCCEEDED(userAttr->getArgumentValueFloat(k, &floatVal)))
    //             {
    //                 print_line("float:", floatVal);
    //             }
    //             else if (SLANG_SUCCEEDED(userAttr->getArgumentValueInt(k, &intVal)))
    //             {
    //                 print_line("int:", intVal);
    //             }
    //             else if (auto str = userAttr->getArgumentValueString(k, &bufSize))
    //             {
    //                 String argument_str = String::utf8(static_cast<const char*>(str), bufSize);
    //                 print_line("string:", argument_str);
    //             }
    //         }
    //     }
    //     auto paramName = param->getName();
    //     auto paramTypeName = paramType->getName();
    //     print_line("Param name: ", static_cast<const char*>(paramName), " type: ", static_cast<const char*>(paramTypeName));
    // }
}

Dictionary SlangShader::get_reflection_info() const {
    return reflection_info;
}

void SlangShader::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_code", "code"), &SlangShader::set_code);
    ClassDB::bind_method(D_METHOD("get_code"), &SlangShader::get_code);
    ClassDB::bind_method(D_METHOD("get_reflection_info"), &SlangShader::get_reflection_info);
}

RID SlangShader::get_rid() const {
	return shader_rid;
}

SlangShader::SlangShader() {
}

SlangShader::~SlangShader() {
}
