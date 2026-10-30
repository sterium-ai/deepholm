extends ScrollContainer

## The debug viewer's independently scrollable information column: the date
## line, the status line, the alert/rejection/room labels boot.gd owns, the
## work table, the workbench panel (F2), the stockpile panel (F5a) and the colonist panel. Layout only;
## boot.gd sets the label texts, except the date line, which refresh() fills
## from the snapshot.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")
const ColonistPanelType = preload("res://scripts/viewer/colonist_panel.gd")
const WorkTablePanelType = preload("res://scripts/viewer/work_table_panel.gd")
const WorkbenchPanelType = preload("res://scripts/viewer/workbench_panel.gd")
const StockpilePanelType = preload("res://scripts/viewer/stockpile_panel.gd")

var content: VBoxContainer
## "Day D · month M · year Y" plus the open calendar window's label, from the
## snapshot's "date" (F0, ADR 060): the core computes it, this only formats it.
var date_label: Label
var status_label: Label
var work_table_panel: WorkTablePanelType
var workbench_panel: WorkbenchPanelType
var stockpile_panel: StockpilePanelType
var colonist_panel: ColonistPanelType
var _text_table: TextTableType
var _world: WorldStateType

func _init() -> void:
	custom_minimum_size.x = 360

## Call after this node is in the tree. `labels` are added under the status
## line, in order.
func build(world: WorldStateType, text_table: TextTableType, labels: Array[Label]) -> void:
	content = VBoxContainer.new()
	content.custom_minimum_size = Vector2(620, 1000)
	add_child(content)
	_text_table = text_table
	_world = world
	date_label = Label.new()
	content.add_child(date_label)
	status_label = Label.new()
	content.add_child(status_label)
	for label in labels:
		content.add_child(label)
	work_table_panel = WorkTablePanelType.new()
	work_table_panel.custom_minimum_size = Vector2(620, 330)
	work_table_panel.setup(world, text_table)
	content.add_child(work_table_panel)
	workbench_panel = WorkbenchPanelType.new()
	workbench_panel.setup(world, text_table)
	content.add_child(workbench_panel)
	stockpile_panel = StockpilePanelType.new()
	stockpile_panel.setup(world, text_table)
	content.add_child(stockpile_panel)
	colonist_panel = ColonistPanelType.new()
	colonist_panel.custom_minimum_size = Vector2(620, 650)
	colonist_panel.setup(world, text_table)
	content.add_child(colonist_panel)
	_refresh_date()

## The colonist ids whose full records the next refresh() reads (the colonist
## panel's window), for boot.gd's WorldState.get_view_snapshot(detail_ids).
func detail_ids() -> Array:
	return colonist_panel.detail_ids()

## `snapshot` is this tick's WorldState.get_view_snapshot() (A9), shared by both panels.
func refresh(snapshot: Dictionary = {}) -> void:
	_refresh_date(snapshot)
	colonist_panel.refresh(snapshot)
	work_table_panel.refresh(snapshot)
	workbench_panel.refresh()
	stockpile_panel.refresh()

func set_world(world: WorldStateType) -> void:
	_world = world
	_refresh_date()
	colonist_panel.world = world
	colonist_panel.forget_rows()
	colonist_panel.refresh()
	work_table_panel.world = world
	work_table_panel.refresh()
	workbench_panel.world = world
	workbench_panel.refresh()
	stockpile_panel.world = world
	stockpile_panel.refresh()

func _refresh_date(snapshot: Dictionary = {}) -> void:
	if snapshot.is_empty():
		snapshot = _world.get_view_snapshot()
	date_label.text = date_text(_text_table, snapshot["date"])

## A calendar.json window label is a text key; one that is not (a test calendar's)
## is shown as written, as the work table's banner does.
static func date_text(text_table: TextTableType, date: Dictionary) -> String:
	var values := [int(date["day"]), int(date["month"]), int(date["year"])]
	var window_label := String(date["window_label"])
	if window_label.is_empty():
		return text_table.format("calendar.date_label", values)
	if text_table.has_string(window_label):
		window_label = text_table.get_string(window_label)
	values.append(window_label)
	return text_table.format("calendar.date_window_label", values)
