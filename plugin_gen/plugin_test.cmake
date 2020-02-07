file(GLOB test_source_files *.h *.cpp)
juce^^ver_major^^_plugin(Juce^^ver_major^^TestInstrument
    BUILD_VST2
    BUILD_VST3
    BUILD_AU
    BUILD_AUV3
    BUILD_AAX
    EDITOR_KEYBOARD_FOCUS
    DESC "test for plugin generation"
    TYPE "instrument"
    CODE "asdf"
    BUNDLE_IDENTIFIER "com.manu.testinstrument"
    MANUFACTURER "TestManu"
    MANUFACTURER_CODE "Tstm"
    AU_EXPORT_PREFIX "testau"
    VER_MAJOR 1
    VER_MINOR 2
    VER_PATCH 3
    SOURCES ${test_source_files}
)
