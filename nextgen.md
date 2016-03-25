Thoughts on redesign
=========================================

Design drawbacks in current implementation:
- Tied to MySQL via sqljocky
=> Refactor out database subsystem
- Events and Queries have to be implemented and named manually, which is error-prone,
time-intensitive and leads to code duplication and bad structure
=> Future framework version might implement RPC, where object methods at the
server can be annotated with queries or events. The actual WebSocket etc are
encapsulated.
- No frontend implementations provided
