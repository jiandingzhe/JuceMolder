# JuceMolder
mold JUCE source files into one

# Synompsis

To mold one JUCE header/source file:
```
perl combine_source.pl path_to_juce/modules/juce_core/juce_core.cpp molded_output/juce_core.cpp
```

To convert whole JUCE into CMake-managed project:
```
perl create_juce_cmake.pl -modules path_to_juce/modules -out juce_cmake_project
```

# Description

JUCE is widely used in audio application development. However, it has quite weird source file layout, where many small implementation source files (such as `juce_core/containers/AbstractFifo.cpp`, `juce_core/containers/AbstractFifo.h`) are included in one bundle file (such as `juce_core.cpp`, `juce_core.h`), and only that bundle file is compiled. In this manner of layout, it is hard for IDE to analyze the implementation files, as each are "incomplete" from their own view.

To solve it, I write this script to mold the implementation source files into the bundle file. This would make each file "complete" and make IDE easyer to analyze.

In addition, as I'm making projects using CMake, I also write a script to generate CMake project according to *JUCE module format* declaration in each JUCE module's header file.

# Usage

- Clone or download this repo.
- If you want to create CMake project, run `create_juce_cmake.pl`.
- If you just want to mold files, run `combine_source.pl` on each h/cpp.

See *Synopsis* chapter for more details.