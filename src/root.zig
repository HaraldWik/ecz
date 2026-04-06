const std = @import("std");
const assert = std.debug.assert;

pub const Component = struct {
    name: @EnumLiteral(),
    type: type,

    pub fn id(self: @This()) u64 {
        return std.hash.Wyhash.hash(0, @tagName(self.name));
    }

    pub fn Layout(comps: []const Component) type {
        var field_names: [comps.len][]const u8 = undefined;
        var field_types: [field_names.len]type = undefined;
        var field_attrs: [field_names.len]std.builtin.Type.StructField.Attributes = @splat(.{});
        for (comps, &field_names, &field_types, &field_attrs) |comp, *field_name, *field_type, *field_attr| {
            field_name.* = @tagName(comp.name);
            field_type.* = std.ArrayList(comp.type);
            field_attr.default_value_ptr = &std.ArrayList(comp.type).empty;
        }
        return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    }
};

pub fn World(comps: []const Component) type {
    return struct {
        const ActualWorld = @This();

        gpa: std.mem.Allocator,

        layout: Layout = .{},
        signatures: std.ArrayList(Entity.Signature) = .empty,

        last_id: Entity.Id = 0,
        despawned_ids: std.ArrayList(Entity.Id) = .empty,

        pub const Layout = Component.Layout(comps);

        pub const Entity = struct {
            world: *ActualWorld,
            id: Id = 0,
            signature: *Signature,

            pub const Id = u32;
            pub const Signature = struct {
                bit_set: std.StaticBitSet(comps.len),

                pub const empty: @This() = .{ .bit_set = .initEmpty() };
            };

            pub fn fromId(world: *ActualWorld, id: Entity.Id) Entity {
                return world.entityFromId(id);
            }

            pub fn despawn(self: @This()) !void {
                try self.world.despawnEntity(self);
            }

            pub fn getComponent(self: @This(), comptime component: Component) component.type {
                return @field(self.world.layout, @tagName(component.name)).items[self.id];
            }

            pub fn getComponentPtr(self: @This(), comptime component: Component) *component.type {
                return &@field(self.world.layout, @tagName(component.name)).items[self.id];
            }

            /// returns a pointer to the uninitialized component
            pub fn addComponent(self: @This(), comptime component: Component) !*component.type {
                return self.world.addEntityComponent(self, component);
            }

            pub fn putComponent(self: @This(), comptime component: Component, value: component.type) !void {
                const new_value_ptr = try self.addComponent(component);
                new_value_ptr.* = value;
            }

            pub fn removeComponent(self: @This(), comptime component: Component) void {
                self.signature.bit_set.setValue(componentSignatureIndex(component), false);
            }
        };

        pub fn init(gpa: std.mem.Allocator) @This() {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *@This()) void {
            self.despawned_ids.deinit(self.gpa);
            self.signatures.deinit(self.gpa);
            inline for (std.meta.fields(Layout)) |field| {
                @field(self.layout, field.name).deinit(self.gpa);
            }
        }

        pub fn entityFromId(self: *@This(), id: Entity.Id) Entity {
            assert(id <= self.last_id);
            return .{
                .world = self,
                .id = id,
                .signature = &self.signatures.items[id],
            };
        }

        pub fn spawnEntity(self: *@This()) !Entity {
            const id = if (self.despawned_ids.items.len != 0) self.despawned_ids.pop().? else id: {
                defer self.last_id += 1;
                break :id self.last_id;
            };

            try self.signatures.ensureTotalCapacity(self.gpa, id + 1);
            if (self.signatures.items.len <= id + 1) self.signatures.items.len = id + 1;

            const signature = &self.signatures.items[id];
            signature.* = .empty;

            return .{ .world = self, .id = id, .signature = signature };
        }

        pub fn despawnEntity(self: *@This(), entity: Entity) !void {
            entity.signature.* = .empty;

            if (entity.id + 1 == self.last_id) {
                self.last_id -= 1;

                while (self.last_id > 0) : (self.last_id -= 1) {
                    const prev_id = self.last_id - 1;
                    const index = std.mem.indexOfScalar(Entity.Id, self.despawned_ids.items, prev_id) orelse break;
                    _ = self.despawned_ids.swapRemove(index);
                }
            } else {
                try self.despawned_ids.append(self.gpa, entity.id);
            }
        }

        pub fn addEntityComponent(self: *@This(), entity: Entity, comptime component: Component) !*component.type {
            comptime verifyComponents(&.{component});
            const array_list: *std.ArrayList(component.type) = &@field(self.layout, @tagName(component.name));
            try array_list.ensureTotalCapacity(self.gpa, self.last_id + 1);
            if (array_list.items.len <= entity.id + 1) array_list.items.len = entity.id + 1;

            entity.signature.bit_set.setValue(componentSignatureIndex(component), true);

            return &array_list.items[entity.id];
        }

        pub fn query(self: *@This(), comptime components: []const Component) QueryIterator(components) {
            comptime verifyComponents(components);
            return .{ .world = self };
        }

        pub fn QueryIterator(components: []const Component) type {
            return struct {
                world: *ActualWorld,
                last_entity: ?Entity = null,

                pub fn next(self: *@This()) ?Entity {
                    const signature_start_index: usize = if (self.last_entity) |entity| entity.id + 1 else 0;

                    for (self.world.signatures.items[signature_start_index..], 0..) |*signature, i| {
                        const id = signature_start_index + i;

                        var found_component_count: usize = 0;
                        inline for (components) |component| {
                            if (signature.bit_set.isSet(componentSignatureIndex(component)))
                                found_component_count += 1;
                        }
                        if (found_component_count != components.len) continue;

                        const found_entity: Entity = .{
                            .world = self.world,
                            .id = @intCast(id),
                            .signature = signature,
                        };

                        self.last_entity = found_entity;
                        return found_entity;
                    }
                    return null;
                }
            };
        }

        fn componentSignatureIndex(comptime component: Component) usize {
            inline for (comps, 0..) |comp, i| {
                if (std.meta.eql(comp, component)) return i;
            }
            unreachable;
        }

        fn verifyComponents(comptime components: []const Component) void {
            inline for (components) |component| {
                if (!@hasField(Layout, @tagName(component.name))) {
                    @compileError("attempted to access unregistered component '" ++ @tagName(component.name) ++ "'");
                }
            }
        }
    };
}
