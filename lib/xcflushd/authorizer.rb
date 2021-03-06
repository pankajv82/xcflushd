require '3scale_client'

module Xcflushd
  class Authorizer

    # Exception raised when the 3scale client is called with the right params
    # but it returns a ServerError. Most of the time this means that 3scale is
    # unreachable.
    class ThreeScaleInternalError < Flusher::XcflushdError
      def initialize(service_id, credentials)
        super("Error renewing auths of service with ID #{service_id} "\
              "and credentials #{credentials}. 3scale is unreachable")
      end
    end

    # Extensions used by the Authorizer
    # In our case we want 3scale to respond with the hierarchy
    EXTENSIONS = { hierarchy: 1 }.freeze
    private_constant :EXTENSIONS

    def initialize(threescale_client)
      @threescale_client = threescale_client
    end

    # Returns the authorization status of all the limited metrics of the
    # application identified by the received (service_id, credentials) pair and
    # also, the authorization of those metrics passed in reported_metrics that
    # are not limited.
    #
    # @return Array<Authorization>
    def authorizations(service_id, credentials, reported_metrics)
      # We can safely assume that reported metrics that do not have an
      # associated report usage are non-limited metrics.

      # First, let's check if there is a problem that has nothing to do with
      # limits (disabled application, bad credentials, etc.).
      auth = with_3scale_error_rescue(service_id, credentials) do
        auths_params = { service_id: service_id,
                         extensions: EXTENSIONS }.merge!(credentials.creds)

        if credentials.oauth?
          threescale_client.oauth_authorize(auths_params)
        else
          threescale_client.authorize(auths_params)
        end
      end

      if !auth.success? && !auth.limits_exceeded?
        return reported_metrics.inject({}) do |acc, metric|
          acc[metric] = Authorization.deny(auth.error_code)
          acc
        end
      end

      auths_according_to_limits(auth, reported_metrics)
    end

    private

    attr_reader :threescale_client

    def next_hit_auth?(usages)
      usages.all? { |usage| usage.current_value < usage.max_value }
    end

    def usage_reports(auth, reported_metrics)
      # We are grouping the reports for clarity. We can change this in the
      # future if it affects performance.
      reports = auth.usage_reports.group_by { |report| report.metric }
      non_limited_metrics = reported_metrics - reports.keys
      non_limited_metrics.each { |metric| reports[metric] = [] }
      reports
    end

    # Returns an array of metric names. The array is guaranteed to have all the
    # parents first, and then the rest.
    # In 3scale, metric hierarchies only have 2 levels. In other words, a
    # metric that has a parent cannot have children.
    def sorted_metrics(metrics, hierarchy)
      # 'hierarchy' is a hash where the keys are metric names and the values
      # are arrays with the names of the children metrics. Only metrics with
      # children and with at least one usage limit appear as keys.
      parent_metrics = hierarchy.keys
      child_metrics = metrics - parent_metrics
      parent_metrics + child_metrics
    end

    def auths_according_to_limits(app_auth, reported_metrics)
      metrics_usage = usage_reports(app_auth, reported_metrics)

      # We need to sort the metrics. When the authorization of a metric is
      # denied, all its children should be denied too. If we check the parents
      # first, when they are denied, we know that we do not need to check the
      # limits for their children. This saves us some work.
      sorted_metrics(metrics_usage.keys, app_auth.hierarchy).inject({}) do |acc, metric|
        unless acc[metric]
          acc[metric] = if next_hit_auth?(metrics_usage[metric])
                          Authorization.allow
                        else
                          auth = Authorization.deny_over_limits
                          children = app_auth.hierarchy[metric]
                          if children
                            children.each do |child_metric|
                              acc[child_metric] = auth
                            end
                          end
                          auth
                        end
        end

        acc
      end
    end

    def with_3scale_error_rescue(service_id, credentials)
      yield
    rescue ThreeScale::ServerError, SocketError
      # We'll get a SocketError if there's a timeout when contacting 3scale.
      raise ThreeScaleInternalError.new(service_id, credentials)
    end
  end
end
