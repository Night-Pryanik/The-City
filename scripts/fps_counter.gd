# scripts/fps_counter.gd
#
# The frame rate counter in the top right corner of the map, next to the Menu
# button. It is a plain label: the visibility is controlled by main_map from the
# setting "Interface → Show FPS counter".
extends Label

# Engine.get_frames_per_second() is an average over the last second and changes on
# every frame; refreshing the text at this interval keeps the number readable
# without hiding a real drop.
const UPDATE_INTERVAL := 0.25

var _elapsed := 0.0

func _ready() -> void:
    # The counter is an overlay: it keeps updating while the tree is paused, like the
    # wall clock next to it.
    process_mode = Node.PROCESS_MODE_ALWAYS
    _refresh()

func _process(delta: float) -> void:
    _elapsed += delta
    if _elapsed < UPDATE_INTERVAL:
        return
    _elapsed = 0.0
    _refresh()

func _refresh() -> void:
    text = "FPS: %d" % Engine.get_frames_per_second()
