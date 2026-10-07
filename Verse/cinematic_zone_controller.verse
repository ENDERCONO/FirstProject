using { /Fortnite.com/Devices }
using { /Fortnite.com/Characters }
using { /Fortnite.com/UI }
using { /Verse.org/Assets }
using { /Verse.org/Random }
using { /Verse.org/Simulation }
using { /UnrealEngine.com/Temporary/Diagnostics }
using { /UnrealEngine.com/Temporary/UI }

# Looping world cinematics + three groups of per-player "death" zones.
#
# 1. LOOPING SEQUENCES
#    StartTrigger kicks off every sequence in LoopSequences. Each one runs on
#    its own independent cycle:
#        Play -> wait SequenceDurationSeconds (10.4) -> Stop
#             -> wait a random cooldown (CooldownMin..CooldownMax) -> Play again
#    One lightweight task per sequence that only ever sits in Sleep — no
#    per-tick polling. Firing StartTrigger while already running is ignored,
#    so loops can never stack. StopTrigger (optional) ends them all.
#    These play for EVERYONE: set each sequence's Visibility to "Everyone" —
#    the no-agent Play() does nothing on any other setting.
#
# 2. MUTATOR ZONE GROUPS (A, B, C)
#    Entering any zone in a group plays that group's cinematic for THAT player
#    only, then after that group's delay shows the shared death screen
#    (death_screen.verse — same screen as ChaseSceneController), stops the
#    cinematic behind the black plate and optionally teleports them.
#    Set each group cinematic's Visibility to "Instigator" so Play(Agent) is
#    client-side for the victim alone.
#
# This file must live in the same Verse module (folder) as death_screen.verse
# and whatever defines SetInDeathSequence, since it calls both directly.

# The per-group settings, built once in OnBegin from the editables below.
cinematic_zone_group := class:
    Name : string
    Cinematic : cinematic_sequence_device
    ScreenDelaySeconds : float
    # Slot 0 is used; empty means "don't teleport".
    Teleporters : []teleporter_device

# Verse has no closures, so one watcher per GROUP binds the group to the zone
# event. Every zone in the group shares the same watcher.
cinematic_zone_watcher := class:
    Controller : CinematicZoneController
    Group : cinematic_zone_group

    Handle(Agent : agent) : void =
        Controller.OnZoneEntered(Agent, Group)

CinematicZoneController := class(creative_device):

    # ── Looping sequences ────────────────────────────────────────────────────

    @editable
    StartTrigger : trigger_device = trigger_device{}

    # Optional. Stops every looping sequence; StartTrigger can start them again.
    @editable
    StopTrigger : trigger_device = trigger_device{}

    # Every sequence here loops on its own timer. Visibility: "Everyone".
    @editable
    LoopSequences : []cinematic_sequence_device = array{}

    # How long one play lasts before it is stopped and the cooldown begins.
    @editable
    SequenceDurationSeconds : float = 10.4

    # Random cooldown between plays, rolled fresh every cycle per sequence.
    @editable
    CooldownMinSeconds : float = 4.0

    @editable
    CooldownMaxSeconds : float = 10.0

    # Random delay (0..this) before each sequence's FIRST play, so they don't
    # all fire on the same frame. 0 = all start together.
    @editable
    StartStaggerMaxSeconds : float = 0.0

    # ── Mutator zone groups ──────────────────────────────────────────────────

    # Off: zones work from the start of the round. On: zones do nothing until
    # StartTrigger has fired (and stop again on StopTrigger).
    @editable
    ZonesRequireStart : logic = false

    # Group A
    @editable
    ZonesA : []mutator_zone_device = array{}

    # Visibility: "Instigator".
    @editable
    CinematicA : cinematic_sequence_device = cinematic_sequence_device{}

    # Seconds from entering the zone to the death screen appearing.
    @editable
    ScreenDelayA : float = 1.0

    # Optional — leave empty to leave the player where they are.
    @editable
    TeleportersA : []teleporter_device = array{}

    # Group B
    @editable
    ZonesB : []mutator_zone_device = array{}

    @editable
    CinematicB : cinematic_sequence_device = cinematic_sequence_device{}

    @editable
    ScreenDelayB : float = 2.0

    @editable
    TeleportersB : []teleporter_device = array{}

    # Group C
    @editable
    ZonesC : []mutator_zone_device = array{}

    @editable
    CinematicC : cinematic_sequence_device = cinematic_sequence_device{}

    @editable
    ScreenDelayC : float = 3.0

    @editable
    TeleportersC : []teleporter_device = array{}

    # ── Death screen art (shared by all groups) ──────────────────────────────
    # Arrays because Verse cannot default-construct a material; slot 0 is used,
    # empty means "not supplied".

    @editable
    DeathScreenMaterials : []material = array{}

    @editable
    DeathTextMaterials : []material = array{}

    @editable
    DeathArtWidth : float = 438.2

    @editable
    DeathArtHeight : float = 107.2

    @editable
    DeathTextFallback : string = "YOU DIED"

    # MUST be an Audio Player set to "Heard by Instigator".
    @editable
    DeathScreenSound : audio_player_device = audio_player_device{}

    # ── Death screen timings ─────────────────────────────────────────────────

    @editable
    RedFadeInSeconds : float = 0.2

    @editable
    RedHoldSeconds : float = 0.1

    @editable
    RedFadeOutSeconds : float = 0.3

    @editable
    ImageHoldSeconds : float = 0.6

    @editable
    ImageFadeOutSeconds : float = 0.4

    @editable
    TextFadeInSeconds : float = 0.2

    @editable
    TextHoldSeconds : float = 1.7

    @editable
    TextFadeOutSeconds : float = 1.0

    @editable
    BlackFadeOutSeconds : float = 1.56

    @editable
    DEBUG : logic = false

    # ── State ────────────────────────────────────────────────────────────────

    var LoopsRunning : logic = false

    # Signalled by StopTrigger; every loop task races against it, so they all
    # end immediately, even mid-Sleep.
    StopLoopsEvent : event() = event(){}

    # Players currently inside a zone sequence. Re-entering a zone (or crossing
    # into another one) while their sequence runs is ignored.
    var BusyPlayers : [agent]logic = map{}

    OnBegin<override>()<suspends>:void =
        StartTrigger.TriggeredEvent.Subscribe(OnStartTriggered)
        StopTrigger.TriggeredEvent.Subscribe(OnStopTriggered)

        RegisterGroup(ZonesA, cinematic_zone_group{
            Name := "A", Cinematic := CinematicA, ScreenDelaySeconds := ScreenDelayA, Teleporters := TeleportersA})
        RegisterGroup(ZonesB, cinematic_zone_group{
            Name := "B", Cinematic := CinematicB, ScreenDelaySeconds := ScreenDelayB, Teleporters := TeleportersB})
        RegisterGroup(ZonesC, cinematic_zone_group{
            Name := "C", Cinematic := CinematicC, ScreenDelaySeconds := ScreenDelayC, Teleporters := TeleportersC})

        Log("Ready — {LoopSequences.Length} looping sequence(s), zones A/B/C: {ZonesA.Length}/{ZonesB.Length}/{ZonesC.Length}")

    RegisterGroup(Zones : []mutator_zone_device, Group : cinematic_zone_group):void =
        Watcher := cinematic_zone_watcher{Controller := Self, Group := Group}
        for (Zone : Zones):
            Zone.AgentEntersEvent.Subscribe(Watcher.Handle)

    # --- Looping sequences ---------------------------------------------------

    OnStartTriggered(MaybeAgent : ?agent):void =
        if (LoopsRunning?):
            Log("Start ignored — loops already running")
            return
        set LoopsRunning = true
        for (Sequence : LoopSequences):
            spawn { LoopSequence(Sequence) }
        Log("Loops started")

    OnStopTriggered(MaybeAgent : ?agent):void =
        if (LoopsRunning?):
            set LoopsRunning = false
            StopLoopsEvent.Signal()
            for (Sequence : LoopSequences):
                Sequence.Stop()
            Log("Loops stopped")

    LoopSequence(Sequence : cinematic_sequence_device)<suspends>:void =
        # Tolerate Min/Max entered the wrong way round in the inspector.
        CooldownLow := Min(CooldownMinSeconds, CooldownMaxSeconds)
        CooldownHigh := Max(CooldownMinSeconds, CooldownMaxSeconds)
        race:
            StopLoopsEvent.Await()
            block:
                if (StartStaggerMaxSeconds > 0.0):
                    Sleep(GetRandomFloat(0.0, StartStaggerMaxSeconds))
                loop:
                    Sequence.Play()
                    Sleep(SequenceDurationSeconds)
                    # Reset so the next Play() starts from frame 0.
                    Sequence.Stop()
                    Sleep(GetRandomFloat(CooldownLow, CooldownHigh))

    # --- Zone sequences ------------------------------------------------------

    # Internal, not <public>: its parameter type cinematic_zone_group is
    # internal, and a public function cannot expose a less-visible type.
    OnZoneEntered(Agent : agent, Group : cinematic_zone_group):void =
        if (ZonesRequireStart?, not LoopsRunning?):
            return
        if (Victim := player[Agent], not BusyPlayers[Victim]?):
            if (set BusyPlayers[Victim] = true):
                Log("Player entered zone group {Group.Name}")
                spawn { PlayZoneSequence(Victim, Group) }

    PlayZoneSequence(Victim : player, Group : cinematic_zone_group)<suspends>:void =
        # Same claim ChaseSceneController makes, so anything else holding the
        # player (e.g. Steam_Falling_Device) lets go before the animation.
        SetInDeathSequence(Victim, true)

        # Client-side: only the victim sees this ("Instigator" visibility).
        Group.Cinematic.Play(Victim)
        Sleep(Group.ScreenDelaySeconds)

        ShowDeathScreen(Victim, Group)

        SetInDeathSequence(Victim, false)
        # Free to trigger a zone again.
        if (set BusyPlayers[Victim] = false):
            Log("Zone group {Group.Name} sequence finished")

    ShowDeathScreen(Victim : player, Group : cinematic_zone_group)<suspends>:void =
        if (PlayerUI := GetPlayerUI[Victim]):
            Screen := MakeDeathScreen(DeathScreenMaterials, DeathTextMaterials, DeathArtWidth, DeathArtHeight, DeathTextFallback)
            PlayerUI.AddWidget(Screen.Root, player_ui_slot{InputMode := ui_input_mode.None, ZOrder := 100})
            PlayerUI.AddWidget(Screen.Blocker, player_ui_slot{InputMode := ui_input_mode.All, ZOrder := 101})
            DeathScreenSound.Play(Victim)

            # Two frames so the plate covers the view before the cinematic
            # camera is released and the teleport lands.
            Sleep(0.0)
            Sleep(0.0)
            Group.Cinematic.Stop(Victim)
            TeleportVictim(Victim, Group)

            DeathScreenPlayVisuals(Screen, MakeTimings())

            # Control back first, then the plate lifts.
            PlayerUI.RemoveWidget(Screen.Blocker)
            DeathScreenFadeAlpha(Screen.Black, 1.0, 0.0, BlackFadeOutSeconds)
            PlayerUI.RemoveWidget(Screen.Root)
        else:
            # No player UI (disconnected mid-sequence) — still release the
            # camera and move them.
            Group.Cinematic.Stop(Victim)
            TeleportVictim(Victim, Group)

    TeleportVictim(Victim : player, Group : cinematic_zone_group):void =
        if (Teleporter := Group.Teleporters[0], Victim.GetFortCharacter[]):
            Teleporter.Teleport(Victim)

    MakeTimings():death_screen_timings =
        death_screen_timings{
            RedFadeIn := RedFadeInSeconds,
            RedHold := RedHoldSeconds,
            RedFadeOut := RedFadeOutSeconds,
            ImageHold := ImageHoldSeconds,
            ImageFadeOut := ImageFadeOutSeconds,
            TextFadeIn := TextFadeInSeconds,
            TextHold := TextHoldSeconds,
            TextFadeOut := TextFadeOutSeconds}

    Log(Message : string):void =
        if (DEBUG?):
            Print("[CinematicZones] {Message}")
