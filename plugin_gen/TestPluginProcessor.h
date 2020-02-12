#pragma once

#include <juce_audio_processors/juce_audio_processors.h>
#include "PluginConfig.h"

class TestProcessor : public juce::AudioProcessor
{
public:
    const juce::String getName() const override { return JucePlugin_Name; }

    void prepareToPlay( double, int ) override {}

    void releaseResources() override {}

    void processBlock( juce::AudioBuffer<float>&, juce::MidiBuffer& ) override {}

    double getTailLengthSeconds() const override { return 0; }

    bool acceptsMidi() const override { return bool( JucePlugin_WantsMidiInput ); }

    bool producesMidi() const override { return bool( JucePlugin_ProducesMidiOutput ); }

    juce::AudioProcessorEditor* createEditor() override;

    bool hasEditor() const override { return true; }

    int getNumPrograms() override { return 1; }

    int getCurrentProgram() override { return 0; }

    void setCurrentProgram( int ) override {}

    const juce::String getProgramName( int ) override { return juce::String(); }

    void changeProgramName( int, const juce::String& ) override {}

    void getStateInformation( juce::MemoryBlock& ) override {}

    void setStateInformation( const void*, int ) override {}
};