#include "TestPluginProcessor.h"

class TestUI: public juce::AudioProcessorEditor
{
public:
    
    TestUI( TestProcessor& );

    virtual ~TestUI() = default;
};