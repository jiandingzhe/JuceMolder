#include "TestPluginProcessor.h"

#include "juce_audio_plugin_client.h"

extern juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new TestProcessor;
}