@tool
extends Node

var terrains: Dictionary = {}
var raw_resources: Dictionary = {}
var products: Dictionary = {}
var improvements: Dictionary = {}
var crafts: Array = []
var buildings: Array = []
var categories: Array = []
var technologies: Array = []
var groups: Array = []
var product_groups: Dictionary = {}

func load_all_data():
    var loader = load("res://scripts/data_loader.gd").new()
    loader.load_all_data()
    terrains = loader.terrains
    raw_resources = loader.raw_resources
    products = loader.products
    improvements = loader.improvements
    crafts = loader.crafts
    buildings = loader.buildings
    categories = loader.categories
    technologies = loader.technologies
    groups = loader.groups
    product_groups = loader.product_groups
