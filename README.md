# Ball

A specification for representing arbitrary code with BSON/JSON.
Built on top of Json schema

# Target:

main target is being able to represent arbitrary code and logic with BSON/JSON data formats

## Why ?

We want to create offline first client apps that share the same business logic as our server, where the code is delivered from the server to the client in versions in run-time.

## Is it useful?

No.

## Is this an example of over-engineering ?

Yes.

## Why not just build your server and client both in js and ship the code to the client as files?

Because interpreted languages are overrated.

## Why call it ball ?

Catchy name

## Is there anything else like this?

Probably, No idea.

## Notes

- I will be writing the spec as dart classes first for quick prototyping, and then transform them to json schema later