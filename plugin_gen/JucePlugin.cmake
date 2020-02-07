
function(juce^^ver_major^^_plugin jplug_name)
    set(switch_opts
        BUILD_VST2
        BUILD_VST3
        BUILD_AU
        BUILD_AUV3
        BUILD_AAX
        BUILD_UNITY
        MIDI_INPUT
        MIDI_OUTPUT
        EDITOR_KEYBOARD_FOCUS
    )
    set(valued_opts
        DESC
        TYPE
        CODE
        BUNDLE_IDENTIFIER
        MANUFACTURER
        MANUFACTURER_EMAIL
        MANUFACTURER_WEBSITE
        MANUFACTURER_CODE
        AU_EXPORT_PREFIX
        VER_MAJOR
        VER_MINOR
        VER_PATCH
    )
    set(multi_opts
        SOURCES
        LINK_LIBRARIES
        APPLE_APP_RESOURCE
        APPLE_PLUGIN_RESOURCE)
    cmake_parse_arguments(jplug "${switch_opts}" "${valued_opts}" "${multi_opts}" ${ARGN})

    set(plugin_code_dir ${JUCE^^ver_major^^_SOURCE_DIR}/plugin_code)

    # directly convert some flags to parameters
    set(JucePlugin_Build_VST        ${jplug_BUILD_VST2})
    set(JucePlugin_Build_VST3       ${jplug_BUILD_VST3})
    set(JucePlugin_Build_AU         ${jplug_BUILD_AU})
    set(JucePlugin_Build_AUv3       ${jplug_BUILD_AUV3})
    set(JucePlugin_Build_AAX        ${jplug_BUILD_AAX})
    set(JucePlugin_Build_Unity      ${jplug_BUILD_UNITY})
    set(JucePlugin_WantsMidiInput               ${jplug_MIDI_INPUT})
    set(JucePlugin_ProducesMidiOutput           ${jplug_MIDI_OUTPUT})
    set(JucePlugin_EditorRequiresKeyboardFocus  ${jplug_EDITOR_KEYBOARD_FOCUS})

    set(JucePlugin_Desc ${jplug_DESC})

    # calculate version code
    math(EXPR jplug_version_code "${jplug_VER_MAJOR} * 65536 + ${jplug_VER_MINOR} * 256 + ${jplug_VER_PATCH}" OUTPUT_FORMAT HEXADECIMAL)

    # determine type
    if(jplug_TYPE STREQUAL "instrument")
        set(jplug_au_main_type "aumu")
        set(jplug_aax_category "AAX_ePlugInCategory_SWGenerators")
        set(jplug_vst_category "kPlugCategSynth")
        set(jplug_vst3_category "")
        set(jplug_iaa_type      "")
        set(JucePlugin_IsSynth 1)
    elseif(jplug_TYPE STREQUAL "effect")
        set(jplug_au_main_type "aufx")
        set(jplug_aax_category "AAX_EPlugInCategory_Effect")
        set(jplug_vst_category "kPlugCategEffect")
        set(jplug_vst3_category "Fx")
        set(jplug_iaa_type      "aurx")
        set(JucePlugin_IsSynth 0)
    else()
        message(FATAL_ERROR "invalid plugin type: ${jplug_TYPE}")
    endif()

    configure_file(${plugin_code_dir}/PluginConfig.h.in PluginConfig.h)

    #
    # predefined source codes of different plugin types
    #
    set(plugin_src
        ${plugin_code_dir}/juce_audio_plugin_client/juce_audio_plugin_client.h
        ${plugin_code_dir}/juce_audio_plugin_client/juce_audio_plugin_client_utils.cpp)
    
    # Avid AAX
    if(jplug_BUILD_AAX)
        if(WIN32)
            list(APPEND plugin_src ${plugin_code_dir}/juce_audio_plugin_client/juce_audio_plugin_client_AAX.cpp)
        elseif(APPLE AND NOT IOS)
            list(APPEND plugin_src ${plugin_code_dir}/juce_audio_plugin_client/juce_audio_plugin_client_AAX.mm)
        endif()
    endif()

    # Audio Unit
    if(APPLE AND jplug_BUILD_AU)
        list(APPEND plugin_src
            ${plugin_code_dir}/juce_audio_plugin_client/juce_audio_plugin_client_AU_1.mm
            ${plugin_code_dir}/juce_audio_plugin_client/juce_audio_plugin_client_AU_2.mm)
    endif()

    if(APPLE AND jplug_BUILD_AUV3)
        list(APPEND plugin_src ${plugin_code_dir}/juce_audio_plugin_client/juce_audio_plugin_client_AUv3.mm)
    endif()

    # VST
    if(APPLE)
        if(jplug_BUILD_VST2 OR jplug_BUILD_VST3)
            list(APPEND plugin_src ${plugin_code_dir}/juce_audio_plugin_client/juce_audio_plugin_client_VST_utils.mm)
        endif()
    elseif(WIN32 OR CMAKE_SYSTEM_NAME STREQUAL "Linux")
        if(jplug_BUILD_VST2)
            list(APPEND plugin_src ${plugin_code_dir}/juce_audio_plugin_client/juce_audio_plugin_client_VST2.cpp)
        endif()
        if(jplug_BUILD_VST3)
            list(APPEND plugin_src ${plugin_code_dir}/juce_audio_plugin_client/juce_audio_plugin_client_VST3.cpp)
        endif()
    endif()
    
    # unity
    if(jplug_BUILD_UNITY)
        list(APPEND plugin_src ${plugin_code_dir}/juce_audio_plugin_client/juce_audio_plugin_client_Unity.cpp)
    endif()

    # standalone application
    set(app_src ${plugin_code_dir}/juce_audio_plugin_client/juce_audio_plugin_client_Standalone.cpp)
    
    #
    # create targets
    #

    # apple-specific resources
    if(APPLE)
        list(APPEND plugin_src ${jplug_APPLE_PLUGIN_RESOURCE})
        list(APPEND app_src ${jplug_APPLE_APP_RESOURCE})
        set_source_files_properties(${jplug_APPLE_PLUGIN_RESOURCE} ${jplug_APPLE_APP_RESOURCE}
            PROPERTIES
                MACOSX_PACKAGE_LOCATION "Resources")
    endif()

    # all sources to an impl library
    if(jplug_SOURCES)
        set(impl_lib ${jplug_name}_impl)
        add_library(${impl_lib} STATIC ${jplug_SOURCES})
        target_link_libraries(${impl_lib} ${jplug_LINK_LIBRARIES} juce^^ver_major^^)
        target_include_directories(${impl_lib} PUBLIC
            ${CMAKE_CURRENT_SOURCE_DIR}
            ${CMAKE_CURRENT_BINARY_DIR})
    endif()

    # plugin
    set(plugin_target ${jplug_name}_plugin)
    add_library(${plugin_target} MODULE ${plugin_src})
    if(impl_lib)
        target_link_libraries(${plugin_target} ${impl_lib})
    else()
        target_link_libraries(${plugin_target} ${jplug_LINK_LIBRARIES} juce^^ver_major^^)
    endif()

    target_include_directories(${plugin_target} PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${CMAKE_CURRENT_BINARY_DIR})

    set_target_properties(${plugin_target} PROPERTIES
        OUTPUT_NAME ${jplug_name}
        BUNDLE 1
        MACOSX_BUNDLE_INFO_PLIST     apple_au.plist.in
        MACOSX_BUNDLE_BUNDLE_NAME    ${jplug_name}
        MACOSX_BUNDLE_GUI_IDENTIFIER ${jplug_BUNDLE_IDENTIFIER}.plugin
        MACOSX_BUNDLE_BUNDLE_VERSION "${jplug_VER_MAJOR}.${jplug_VER_MINOR}.${jplug_VER_PATCH}"
    )

    # standalone application
    set(app_target ${jplug_name}_app)
    add_executable(${app_target} MACOSX_BUNDLE ${app_src})
    if(impl_lib)
        target_link_libraries(${app_target} ${impl_lib})
    else()
        target_link_libraries(${app_target} ${jplug_LINK_LIBRARIES} juce^^ver_major^^)
    endif()

    target_include_directories(${app_target} PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${CMAKE_CURRENT_BINARY_DIR})
    
    set_target_properties(${app_target} PROPERTIES
        OUTPUT_NAME ${jplug_name}
        MACOSX_BUNDLE                1
        MACOSX_BUNDLE_INFO_PLIST     apple_app.plist.in
        MACOSX_BUNDLE_BUNDLE_NAME    ${jplug_name}
        MACOSX_BUNDLE_GUI_IDENTIFIER ${jplug_BUNDLE_IDENTIFIER}.app
        MACOSX_BUNDLE_BUNDLE_VERSION "${jplug_VER_MAJOR}.${jplug_VER_MINOR}.${jplug_VER_PATCH}"
        WIN32_EXECUTABLE 1
    )

    # symbol table visibility
    if(NOT MSVC)
        target_compile_options(${plugin_target} PRIVATE -fvisibility=hidden)
        target_compile_options(${app_target}    PRIVATE -fvisibility=hidden)
    endif()

endfunction()
