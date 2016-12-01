require "dl/import"
require "midilib"

module Enumerable
  def rest
    return [] if empty?
    self[1..-1]
  end
end

class LiveMIDI
  ON  = 0x90
  OFF = 0x80
  PC  = 0xC0

  attr_reader :interval

  def self.use(bpm = 120)
    return @singleton = new(bpm) if @singleton.nil?
    @singleton.bpm = bpm
    @singleton.reset
    @singleton
  end

  def initialize(bpm = 120)
    self.bpm = bpm
    @timer = Timer.get(@interval / 10)
    @channel_manager = ChannelManager.new(16)
    open
  end

  def bpm=(bpm)
    @interval = 60.0 / bpm
  end

  def instrument(preset, channel = nil)
    channel = @channel_manager.allocate(channel)
    program_change(channel, preset)
    Instrument.new(self, channel)
  end

  def reset
    @channel_manager.reset
  end

  def play(channel, note, duration, velocity = 100, time = nil)
    on_time = time || Time.now.to_f
    @timer.at(on_time) { note_on(channel, note, velocity) }

    off_time = on_time + duration
    @timer.at(off_time) { note_off(channel, note, velocity) }
  end

  def note_on(channel, note, velocity = 64)
    puts "NOTE ON  (#{Time.now.to_f}) #{channel} #{note} #{velocity}"
    message(ON | channel, note, velocity)
  end

  def note_off(channel, note, velocity = 64)
    puts "NOTE OFF (#{Time.now.to_f}) #{channel} #{note} #{velocity}"
    message(OFF | channel, note, velocity)
  end

  def program_change(channel, preset)
    message(PC | channel, preset)
  end
end

class NoMIDIDestinationsError < StandardError; end
class UnsupportedOSError < StandardError; end

if RUBY_PLATFORM.include?("mswin")

  class LiveMIDI
    module C
      extend DL::Importer
      dlload "winmm"

      extern "int midiOutOpen(HMIDIOUT*, int, int, int, int)"
      extern "int midiOutClose(int)"
      extern "int midiOutShortMsg(int, int)"
    end

    def open
      @device = DL.malloc(DL.sizeof("I"))
      C.midiOutOpen(@device, -1, 0, 0, 0)
    end

    def close
      C.midiOutClose(@device.ptr.to_i)
    end

    def message(one, two = 0, three = 0)
      message = one + (two << 8) + (three << 16)
      C.midiOutShortMsg(@device.ptr.to_i, message)
    end
  end

elsif RUBY_PLATFORM.include?("darwin")

  class LiveMIDI
    module C
      extend DL::Importer
      dlload "/System/Library/Frameworks/CoreMIDI.framework/Versions/Current/CoreMIDI"

      extern "int MIDIClientCreate(void *, void *, void *, void *)"
      extern "int MIDIClientDispose(void *)"
      extern "int MIDIGetNumberOfDestinations()"
      extern "void * MIDIGetDestination(int)"
      extern "int MIDIOutputPortCreate(void *, void *, void *)"
      extern "void * MIDIPacketListInit(void *)"
      extern "void * MIDIPacketListAdd(void *, int, void *, int, int, void *)"
      extern "int MIDISend(void *, void *, void *)"
    end

    module CF
      extend DL::Importer
      dlload "/System/Library/Frameworks/CoreFoundation.framework/Versions/Current/CoreFoundation"

      extern "void * CFStringCreateWithCString (void *, char *, int)"
    end

    def open
      client_name = CF.CFStringCreateWithCString(nil, "RubyMIDI", 0)
      @client = DL::CPtr.new(0)
      C.MIDIClientCreate(client_name, nil, nil, @client.ref)

      port_name = CF.CFStringCreateWithCString(nil, "Output", 0)
      @outport = DL::CPtr.new(0)
      C.MIDIOutputPortCreate(@client, port_name, @outport.ref)

      num = C.MIDIGetNumberOfDestinations()
      raise NoMIDIDestinationsError if num < 1
      @destination = C.MIDIGetDestination(0)
    end

    def close
      C.MIDIClientDispose(@client)
    end

    def message(*args)
      format = "C" * args.size
      bytes = DL::CPtr.to_ptr(args.pack(format))
      packet_list = DL.malloc(256)
      packet_ptr  = C.MIDIPacketListInit(packet_list)
      C.MIDIPacketListAdd(packet_list, 256, packet_ptr, 0, args.size, bytes)
      C.MIDISend(@outport, @destination, packet_list)
    end
  end

elsif RUBY_PLATFORM.include?("linux")

  class LiveMIDI
    module C
      extend DL::Importable
      dlload "libasound.so"

      extern "int snd_rawmidi_open(void*, void*, char*, int)"
      extern "int snd_rawmidi_close(void*)"
      extern "int snd_rawmidi_write(void*, void*, int)"
      extern "int snd_rawmidi_drain(void*)"
    end

    def open
      @output = DL::CPtr.new(0)
      C.snd_rawmidi_open(nil, @output.ref, "virtual", 0)
    end

    def close
      C.snd_rawmidi_close(@output)
    end

    def message(*args)
      format = "C" * args.size
      bytes = DL::CPtr.to_ptr(args.pack(format))
      C.snd_rawmidi_write(@output, bytes, args.size)
      C.snd_rawmidi_drain(@output)
    end
  end

else
  raise UnsupportedOSError, RUBY_PLATFORM
end

class Instrument
  def initialize(midi, channel)
    @midi = midi
    @channel = channel
  end

  def play(*args)
    @midi.play(@channel, *args)
  end

  def pattern(base, string)
    pattern = Pattern.new(base, string)
    interval = @midi.interval

    proc do |b|
      note, duration = pattern[b]
      length = interval * duration - (interval * 0.10)
      play(note, length) if note
    end
  end
end

class ChannelManager
  class NoUnallocatedChannelsError < StandardError; end
  class ChannelAlreadyInUseError < StandardError; end

  def initialize(total)
    @total = total
    reset
  end

  def reset
    @channels = (0...@total).to_a
  end

  def allocate(channel = nil)
    raise NoUnallocatedChannelsError if @channels.empty?
    return @channels.shift if channel.nil?
    raise ChannelAlreadyInUseError, channel unless @channels.include?(channel)

    @channels.delete(channel)
    channel
  end

  def release(channel)
    @channels.push(channel)
    @channels.sort!
  end
end

class Timer
  def self.get(interval)
    @timers ||= {}
    return @timers[interval] if @timers[interval]
    @timers[interval] = new(interval)
  end

  def initialize(resolution)
    @resolution = resolution
    @queue = []

    Thread.new do
      loop do
        dispatch
        sleep(@resolution)
      end
    end
  end

  def at(time, &block)
    time = time.to_f if time.is_a?(Time)
    @queue.push [time, block]
  end

  private

  def dispatch
    now = Time.now.to_f
    # Switch to minheap if performance ever suffers.
    ready, @queue = @queue.partition { |time, _proc| time <= now }
    ready.each { |time, proc| proc.call(time) }
  end
end

class Metronome
  def initialize(bpm)
    @midi = LiveMIDI.new
    @midi.program_change(0, 115)
    @interval = 60.0 / bpm
    @timer = Timer.get(@interval / 10)
    now = Time.now.to_f
    register_next_bang(now)
  end

  def register_next_bang(time)
    @timer.at(time) do |this_time|
      register_next_bang(this_time + @interval)
      bang
    end
  end

  def bang
    @midi.play(0, 84, 0.1, 100, Time.now.to_f + 0.2)
  end
end

class Pattern
  def initialize(base, string)
    @base = base
    @seq = parse(string)
  end

  def [](index)
    value, duration = @seq[index % @seq.size]
    return value, duration if value.nil?
    [@base + value, duration]
  end

  def size
    @seq.size
  end

  private

  def parse(string)
    characters = string.split(//)
    no_spaces = characters.grep(/\S/)
    # Spaces can be used for separating measures
    build(no_spaces)
  end

  def build(list)
    return [] if list.empty?
    duration = 1 + run_length(list.rest)
    value = case list.first
      when /-|=/ then nil
      when /\D/ then 0
      else list.first.to_i
    end
    [[value, duration]] + build(list.rest)
  end

  def run_length(list)
    return 0 if list.empty?
    return 0 if list.first != "="
    1 + run_length(list.rest)
  end
end

class SongPlayer
  def initialize(player, bpm, pattern)
    @player = player
    @interval = 60.0 / bpm
    @pattern = Pattern.new(60, pattern)
    @timer = Timer.get(@interval / 10)
    @count = 0
    play(Time.now.to_f)
  end

  def play(time)
    note, duration = @pattern[@count]
    @count += 1
    return if @count >= @pattern.size

    length = @interval * duration - (@interval * 0.10)
    @player.play(0, note, length) unless note.nil?
    @timer.at(time + @interval) { |at| play(at) }
  end
end

class Tapper
  def initialize(player, length, base, pattern)
    @player = player
    @length = length
    @pattern = Pattern.new(base, pattern)
    @count = 0
  end

  def run
    loop do
      gets
      note, duration = @pattern[@count]
      @player.play(0, note, @length * duration) if note
      @count += 1
    end
  end
end

class FileMIDI
  attr_reader :interval

  def initialize(bpm)
    @bpm = bpm
    @interval = 60.0 / bpm
    @channel_manager = ChannelManager.new(16)

    @base = Time.now.to_f
    @seq = MIDI::Sequence.new

    header_track = MIDI::Track.new(@seq)
    @seq.tracks << header_track
    header_track.events << MIDI::Tempo.new(MIDILIB::Tempo.bpm_to_mpq(@bpm))

    @tracks = []
    @last = []
  end

  def new_track(channel)
    track = MIDI::Track.new(@seq)
    @tracks[channel] = track
    @seq.tracks << track
    track
  end

  def program_change(channel, preset)
    track = new_track(channel)
    # Bind the preset to channel 0, since each channel has it's own track
    track.events << MIDI::ProgramChange.new(0, preset, 0)
  end

  def channel_track(channel)
    @tracks[channel] || new_track(channel)
  end

  def instrument(preset, channel = nil)
    channel = @channel_manager.allocate(channel)
    program_change(channel, preset)
    Instrument.new(self, channel)
  end

  def reset
    @channel_manager.reset
  end

  def play(channel, note, duration = 1, velocity = 100, time = nil)
    time ||= Time.now.to_f
    on_delta = time - (@last[channel] || time)
    off_delta = duration * @interval
    @last[channel] = time
    track = channel_track(channel)
    track.events << MIDI::NoteOnEvent.new(0, note, velocity, seconds_to_delta(on_delta))
    track.events << MIDI::NoteOffEvent.new(0, note, velocity, seconds_to_delta(off_delta))
  end

  def seconds_to_delta(secs)
    bps = 60.0 / @bpm
    beats = secs / bps
    @seq.length_to_delta(beats)
  end

  def save(output_filename)
    File.open(output_filename, "wb") do |file|
      @seq.write(file)
    end
  end
end

class Player
  attr_reader :tick
  def initialize
    bpm(120)
    reset
  end

  def reset
    @callbacks = []
    @closebacks = []
  end

  def bpm(beats_per_minute = nil)
    unless beats_per_minute.nil?
      @bpm = beats_per_minute
      @tick = 60.0 / beats_per_minute
    end
    @bpm
  end

  def bang(callback1 = nil, &callback2)
    @callbacks.push(callback1) if callback1
    @callbacks.push(callback2) if callback2
  end

  def close(closeback1 = nil, &closeback2)
    @closebacks.push(closeback1) if closeback1
    @closebacks.push(closeback2) if closeback2
  end

  def on_bang(b)
    @callbacks.each { |callback| callback.call(b) }
  end

  def on_close
    @closebacks.each(&:call)
  end
end

class Monitor
  class NonExistantFileError < StandardError; end
  class UnreadableFileError < StandardError; end

  def initialize(filename)
    raise NonExistantFileError, filename unless File.exist?(filename)
    raise UnreadableFileError, filename unless File.readable?(filename)

    # Reload timer is independent of other times, every half second should be ok
    @timer = Timer.get(0.5)
    @filename = filename
    @bangs = 0
    @players = [Player.new]

    ingest
  end

  def ingest
    code = File.read(@filename)

    dup = @players.last.dup
    begin
      dup.reset
      dup.instance_eval(code)
      @players.push(dup)
    rescue
      puts "LOAD ERROR: #{$!}"
    end

    @load_time = Time.now.to_i
  end

  def modified?
    File.mtime(@filename).to_i > @load_time
  end

  def run(now = nil)
    now ||= Time.now.to_f
    ingest if modified?

    begin
      @players.last.on_bang(@bangs)
    rescue
      puts "RUN ERROR: #{$!}"
      @players.pop
      retry unless @players.empty?
    end

    @bangs += 1

    @timer.at(now + @players.last.tick) { |time| run(time) }
  end

  def run_forever
    run
    # If run somehow exits, let's just wait for heat death
    loop { sleep(10) }
  end
end
