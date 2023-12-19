# frozen_string_literal: true
require_relative '../../puppet/transaction'

# This class stores, routes, and responds to events generated while evaluating
# a transaction.
#
# @api private
class Puppet::Transaction::EventManager
  # @!attribute [r] transaction
  #   @return [Puppet::Transaction] The transaction associated with this event manager.
  attr_reader :transaction

  # @!attribute [r] events
  #   @todo Determine if this instance variable is used for anything aside from testing.
  #   @return [Array<Puppet::Transaction::Events>] A list of events that can be
  #     handled by the target resource. Events that cannot be handled by the
  #     target resource will be discarded.
  attr_reader :events

  def initialize(transaction)
    @transaction = transaction
    @event_queues = {}
    @events = []
  end

  def relationship_graph
    transaction.relationship_graph
  end

  # Respond to any queued events for this resource.
  def process_events(resource)
    restarted = false
    queued_events(resource) do |callback, events|
      r = process_callback(resource, callback, events)
      restarted ||= r
    end

    if restarted
      queue_events(resource, [resource.event(:name => :restarted, :status => "success")])

      transaction.resource_status(resource).restarted = true
    end
  end

  # Queues events for other resources to respond to.  All of these events have
  # to be from the same resource.
  #
  # @param resource [Puppet::Type] The resource generating the given events
  # @param events [Array<Puppet::Transaction::Event>] All events generated by this resource
  # @return [void]
  def queue_events(resource, events)
    #@events += events

    # Do some basic normalization so we're not doing so many
    # graph queries for large sets of events.
    events.inject({}) do |collection, event|
      collection[event.name] ||= []
      collection[event.name] << event
      collection
    end.collect do |_name, list|
      # It doesn't matter which event we use - they all have the same source
      # and name here.
      event = list[0]

      # Collect the targets of any subscriptions to those events.  We pass
      # the parent resource in so it will override the source in the events,
      # since eval_generated children can't have direct relationships.
      received = (event.name != :restarted)
      relationship_graph.matching_edges(event, resource).each do |edge|
        received ||= true unless edge.target.is_a?(Puppet::Type.type(:whit))
        method = edge.callback
        next unless method
        next unless edge.target.respond_to?(method)

        queue_events_for_resource(resource, edge.target, method, list)
      end
      @events << event if received

      queue_events_for_resource(resource, resource, :refresh, [event]) if resource.self_refresh? and ! resource.deleting?
    end

    dequeue_events_for_resource(resource, :refresh) if events.detect { |e| e.invalidate_refreshes }
  end

  def dequeue_all_events_for_resource(target)
    callbacks = @event_queues[target]
    if callbacks && !callbacks.empty?
      target.info _("Unscheduling all events on %{target}") % { target: target }
      @event_queues[target] = {}
    end
  end

  def dequeue_events_for_resource(target, callback)
    target.info _("Unscheduling %{callback} on %{target}") % { callback: callback, target: target }
    @event_queues[target][callback] = [] if @event_queues[target]
  end

  def queue_events_for_resource(source, target, callback, events)
    whit = Puppet::Type.type(:whit)

    # The message that a resource is refreshing the completed-whit for its own class
    # is extremely counter-intuitive. Basically everything else is easy to understand,
    # if you suppress the whit-lookingness of the whit resources
    refreshing_c_whit = target.is_a?(whit) && target.name =~ /^completed_/

    if refreshing_c_whit
      source.debug "The container #{target} will propagate my #{callback} event"
    else
      source.info _("Scheduling %{callback} of %{target}") % { callback: callback, target: target }
    end

    @event_queues[target] ||= {}
    @event_queues[target][callback] ||= []
    @event_queues[target][callback].concat(events)
  end

  def queued_events(resource)
    callbacks = @event_queues[resource]
    return unless callbacks

    callbacks.each do |callback, events|
      yield callback, events unless events.empty?
    end
  end

  private

  # Should the callback for this resource be invoked?
  # @param resource [Puppet::Type] The resource to be refreshed
  # @param events [Array<Puppet::Transaction::Event>] A list of events
  #   associated with this callback and resource.
  # @return [true, false] Whether the callback should be run.
  def process_callback?(resource, events)
    !(events.all? { |e| e.status == "noop" } || resource.noop?)
  end

  # Processes callbacks for a given resource.
  #
  # @param resource [Puppet::Type] The resource receiving the callback.
  # @param callback [Symbol] The name of the callback method that will be invoked.
  # @param events [Array<Puppet::Transaction::Event>] A list of events
  #   associated with this callback and resource.
  # @return [true, false] Whether the callback was successfully run.
  def process_callback(resource, callback, events)
    if !process_callback?(resource, events)
      process_noop_events(resource, callback, events)
      return false
    end

    resource.send(callback)

    if not resource.is_a?(Puppet::Type.type(:whit))
      message = n_("Triggered '%{callback}' from %{count} event", "Triggered '%{callback}' from %{count} events", events.length) % { count: events.length, callback: callback }
      resource.notice message
      add_callback_status_event(resource, callback, message, "success")
    end

    return true
  rescue => detail
    resource_error_message = _("Failed to call %{callback}: %{detail}") % { callback: callback, detail: detail }
    resource.err(resource_error_message)
    transaction.resource_status(resource).failed_to_restart = true
    transaction.resource_status(resource).fail_with_event(resource_error_message)
    resource.log_exception(detail)
    return false
  end

  def add_callback_status_event(resource, callback, message, status)
    options = { message: message, status: status, name: callback.to_s }
    event = resource.event options
    transaction.resource_status(resource) << event if event
  end

  def process_noop_events(resource, callback, events)
    resource.notice n_("Would have triggered '%{callback}' from %{count} event", "Would have triggered '%{callback}' from %{count} events", events.length) % { count: events.length, callback: callback }

    # And then add an event for it.
    queue_events(resource, [resource.event(:status => "noop", :name => :noop_restart)])
  end
end
