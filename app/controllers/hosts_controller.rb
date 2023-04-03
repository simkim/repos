class HostsController < ApplicationController
  def show
    @host = Host.find_by_name!(params[:id])

    scope = @host.repositories.where.not(last_synced_at:nil)

    sort = params[:sort].presence || 'updated_at'
    if params[:order] == 'asc'
      scope = scope.order(Arel.sql(sort).asc.nulls_last)
    else
      scope = scope.order(Arel.sql(sort).desc.nulls_last)
    end

    @pagy, @repositories = pagy_countless(scope)
  end

  def topic
    @host = Host.find_by_name!(params[:id])

    scope = @host.repositories.where.not(last_synced_at:nil)

    scope = scope.topic(params[:topic])

    sort = params[:sort].presence || 'updated_at'
    if params[:order] == 'asc'
      scope = scope.order(Arel.sql(sort).asc.nulls_last)
    else
      scope = scope.order(Arel.sql(sort).desc.nulls_last)
    end

    @related_topics = (scope.pluck(:topics).flatten - [@keyword]).inject(Hash.new(0)) { |h, e| h[e] += 1; h }.sort_by { |_, v| -v }.first(100)

    @pagy, @repositories = pagy(scope)
  end
end