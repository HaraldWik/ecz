const std = @import("std");
const ecz = @import("ecz");

const World = ecz.World(&.{
    component.person,
    component.profession,
});

const component = struct {
    const person: ecz.Component = .{ .name = .person, .type = Person };
    const profession: ecz.Component = .{ .name = .profession, .type = Profession };
};

const Person = struct {
    name: []const u8,
    age: u8,
};

const Profession = enum {
    doctor,
    musician,
    teacher,
    lawyer,
    carpenter,
    game_developer,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var world: World = .init(gpa);
    defer world.deinit();

    try removingAndAdding(&world);
    try doctorBob(&world);
    try professions(&world);

    std.debug.print("professions count {d}\npeople count {d}\n", .{ @field(world.layout, @tagName(component.profession.name)).items.len, @field(world.layout, @tagName(component.person.name)).items.len });
}

pub fn removingAndAdding(world: *World) !void {
    const first_entity = try world.spawnEntity();
    std.debug.print("first: {d}\n", .{first_entity.id});
    try first_entity.despawn();

    const second_entity = try world.spawnEntity();
    const third_entity = try world.spawnEntity();
    std.debug.print("second: {d}\n", .{second_entity.id});
    std.debug.print("third: {d}\n", .{third_entity.id});
    try second_entity.despawn();
    try third_entity.despawn();
}

pub fn doctorBob(world: *World) !void {
    const entity = try world.spawnEntity();

    const person: *Person = try entity.addComponent(component.person);
    person.* = .{ .name = "Bob", .age = 13 };

    person.age += 20;

    try entity.putComponent(component.profession, .doctor);

    std.debug.print("doctorBob\n", .{});
    std.debug.print("\tentity: {d} with signature {b:02} is the {d} year old {t} {s}\n", .{
        entity.id,
        entity.signature.bit_set.mask,
        person.age,
        entity.getComponent(component.profession),
        person.name,
    });
}

pub fn professions(world: *World) !void {
    // initialize one entity for each profession
    inline for (std.meta.fields(Profession)) |field| {
        const entity = try world.spawnEntity();
        try entity.putComponent(component.profession, std.meta.stringToEnum(Profession, field.name).?);
    }

    std.debug.print("professions\n", .{});

    const bob: World.Entity = .fromId(world, 0);
    bob.removeComponent(component.profession);

    var it = world.query(&.{component.profession});
    while (it.next()) |entity| {
        std.debug.print("\tfound entity {d} with profession {t}\n", .{ entity.id, entity.getComponent(component.profession) });
    }
}
