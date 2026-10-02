# frozen_string_literal: true

# ticket_ref -- the ONE ticket-ref parser (DND-1488).
#
# Which ticket a branch or a title names. Required by ai/bin/lead-time (which
# reads the PR's ticket) and ai/lib/athena_telemetry.rb (which reads the unit
# of work from the branch). Pure Domain: no I/O, no requires, and nothing at
# the top level but the TicketRef module, so requiring it never touches the
# caller's namespace (a CLI's own `main` stays the CLI's).
module TicketRef
  # A ticket reference: 2-10 letters, a hyphen, a number (DND-1318, dnd-1318).
  TICKET_REF_RE = /(?<![A-Za-z0-9])([A-Za-z]{2,10})-(\d{1,7})(?![0-9])/.freeze

  module_function

  # Which ticket a request works: the ticket its branch names, else the one
  # its title names, counting only `prefixes` (the trackers that record a
  # start: DND, and the work tracker's prefix when the overlay gives it,
  # DND-1341). -> ["DND-1318", nil] or [nil, reason]. Ordinary words shaped
  # like a ticket (resync-404, utf-8, ruby-34) are not one. Two different
  # tickets in one place are not a guess. With no such ticket anywhere, the
  # reason names any other ref it saw, and it is never a silent fallback to
  # some other start.
  def ticket_ref(branch:, title:, prefixes: ["DND"])
    names = prefixes.join(" or ")
    places = [["branch", branch], ["title", title]]
    places.each do |where, text|
      refs = (where == "title" ? subject_refs(text) : refs_in(text)).select { |r| prefixes.include?(r.split("-", 2).first) }
      return [refs.first, nil] if refs.size == 1
      return [nil, "its #{where} names several #{names} tickets (#{refs.join(', ')})"] if refs.size > 1
    end
    others = places.flat_map { |_w, t| refs_in(t) }.uniq
    return [nil, "it names no #{names} ticket (only #{others.join(', ')})"] unless others.empty?

    [nil, "neither its branch nor its title names a ticket, so no In Progress time can be read"]
  end

  # The tickets a commit subject or PR title works: the refs in its lead (the
  # text before the first ": "), when the lead names any; else every ref it
  # names. A ref after the lead is a mention ("DND-1812: x follows gen_saas
  # DND-1768" works DND-1812 only). A lead naming only another tracker's ref
  # is that ticket's, so the caller's prefix filter then finds none.
  def subject_refs(text)
    lead, rest = text.to_s.split(": ", 2)
    lead_refs = rest.nil? ? [] : refs_in(lead)
    return refs_in(text) if lead_refs.empty?

    lead_refs
  end

  # Every distinct ticket-shaped ref in `text`, upcased, in order of first
  # mention. nil reads as "".
  def refs_in(text)
    text.to_s.scan(TICKET_REF_RE).map { |p, n| "#{p.upcase}-#{n}" }.uniq
  end
end
