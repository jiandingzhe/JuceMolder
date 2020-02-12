#include "TestPluginUI.h"
#include "TestPluginProcessor.h"

TestUI::TestUI( TestProcessor& processor )
    : AudioProcessorEditor( processor )
{
}

juce::AudioProcessorEditor* TestProcessor::createEditor()
{
    return new TestUI( *this );
}
