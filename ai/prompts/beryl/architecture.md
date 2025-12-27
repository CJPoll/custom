# architecture

Let's define any mermaid diagrams that would be useful for implementation or communication of that implementation to other engineers in this feature's `architecture.md`, the path to which is in context.

The system should be organized into 4 different "buckets":
- UI/View Code
- Side Effects (e.g. ports/adapters in Hexagonal Architecture)
- Side-Effect-Free domain code (domain logic)
- Orchestration between these buckets

Each of these buckets SHOULD be represented by different classes in the
implementation.

UI code should be isolated into classes that are for UI code. HTML/CSS/JS is
often in this bucket for web applications, as is GTK or other UI framework code.

Side Effects should be isolated into classes that are for side effects,
following the ports/adapters idea from Hexagonal Architecture. Database queries
(both reads and updates), filesystem interaction, sending emails, and the like
all belong in this bucket, with focused classes for different concerns.

Domain logic should be isolated into classes that are for domain logic, with
testability (e.g. unit testing) being a first-class concern in designing the
classes, methods, interfaces, etc. for this bucket.

Orchestration logic coordinating control flow between these buckets is a
separate concern, corresponding to Service Objects in Hexagonal Architecture or
Use Cases in Clean Architecture.

$ARGUMENTS
