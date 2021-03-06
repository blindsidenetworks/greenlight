# frozen_string_literal: true

# BigBlueButton open source conferencing system - http://www.bigbluebutton.org/.
#
# Copyright (c) 2018 BigBlueButton Inc. and by respective authors (see below).
#
# This program is free software; you can redistribute it and/or modify it under the
# terms of the GNU Lesser General Public License as published by the Free Software
# Foundation; either version 3.0 of the License, or (at your option) any later
# version.
#
# BigBlueButton is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
# PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License along
# with BigBlueButton; if not, see <http://www.gnu.org/licenses/>.

class AdminsController < ApplicationController
  include Pagy::Backend
  include Themer
  include Emailer
  include Recorder
  include Rolify

  manage_users = [:edit_user, :promote, :demote, :ban_user, :unban_user, :approve, :reset]

  authorize_resource class: false
  before_action :find_user, only: manage_users
  before_action :verify_admin_of_user, only: manage_users

  # GET /admins
  def index
    # Initializa the data manipulation variables
    @search = params[:search] || ""
    @order_column = params[:column] && params[:direction] != "none" ? params[:column] : "created_at"
    @order_direction = params[:direction] && params[:direction] != "none" ? params[:direction] : "DESC"

    @role = params[:role] ? Role.find_by(name: params[:role], provider: @user_domain) : nil

    @pagy, @users = pagy(user_list)
  end

  # GET /admins/site_settings
  def site_settings
  end

  # GET /admins/server_recordings
  def server_recordings
    server_rooms = if Rails.configuration.loadbalanced_configuration
      Room.includes(:owner).where(users: { provider: @user_domain }).pluck(:bbb_id)
    else
      Room.pluck(:bbb_id)
    end

    @search, @order_column, @order_direction, recs =
      all_recordings(server_rooms, params.permit(:search, :column, :direction), true, true)

    @pagy, @recordings = pagy_array(recs)
  end

  # MANAGE USERS

  # GET /admins/edit/:user_uid
  def edit_user
  end

  # POST /admins/ban/:user_uid
  def ban_user
    @user.roles = []
    @user.add_role :denied
    redirect_to admins_path, flash: { success: I18n.t("administrator.flash.banned") }
  end

  # POST /admins/unban/:user_uid
  def unban_user
    @user.remove_role :denied
    @user.add_role :user
    redirect_to admins_path, flash: { success: I18n.t("administrator.flash.unbanned") }
  end

  # POST /admins/approve/:user_uid
  def approve
    @user.remove_role :pending

    send_user_approved_email(@user)

    redirect_to admins_path, flash: { success: I18n.t("administrator.flash.approved") }
  end

  # POST /admins/invite
  def invite
    emails = params[:invite_user][:email].split(",")

    emails.each do |email|
      invitation = create_or_update_invite(email)

      send_invitation_email(current_user.name, email, invitation.invite_token)
    end

    redirect_to admins_path
  end

  # GET /admins/reset
  def reset
    @user.create_reset_digest

    send_password_reset_email(@user)

    redirect_to admins_path, flash: { success: I18n.t("administrator.flash.reset_password") }
  end
  # SITE SETTINGS

  # POST /admins/update_settings
  def update_settings
    @settings.update_value(params[:setting], params[:value])

    flash_message = I18n.t("administrator.flash.settings")

    if params[:value] == "Default Recording Visibility"
      flash_message += ". " + I18n.t("administrator.site_settings.recording_visibility.warning")
    end

    redirect_to admin_site_settings_path, flash: { success: flash_message }
  end

  # POST /admins/color
  def coloring
    @settings.update_value("Primary Color", params[:value])
    @settings.update_value("Primary Color Lighten", color_lighten(params[:value]))
    @settings.update_value("Primary Color Darken", color_darken(params[:value]))
    redirect_to admin_site_settings_path, flash: { success: I18n.t("administrator.flash.settings") }
  end

  # POST /admins/registration_method/:method
  def registration_method
    new_method = Rails.configuration.registration_methods[params[:value].to_sym]

    # Only allow change to Join by Invitation if user has emails enabled
    if !Rails.configuration.enable_email_verification && new_method == Rails.configuration.registration_methods[:invite]
      redirect_to admin_site_settings_path,
        flash: { alert: I18n.t("administrator.flash.invite_email_verification") }
    else
      @settings.update_value("Registration Method", new_method)
      redirect_to admin_site_settings_path,
        flash: { success: I18n.t("administrator.flash.registration_method_updated") }
    end
  end

  # ROLES

  # GET /admins/roles
  def roles
    @roles = all_roles(params[:selected_role])
  end

  # POST /admins/role
  # This method creates a new role scoped to the users provider
  def new_role
    new_role = create_role(params[:role][:name])

    return redirect_to admin_roles_path, flash: { alert: I18n.t("administrator.roles.invalid_create") } if new_role.nil?

    redirect_to admin_roles_path(selected_role: new_role.id)
  end

  # PATCH /admin/roles/order
  # This updates the priority of a site's roles
  # Note: A lower priority role will always get used before a higher priority one
  def change_role_order
    unless update_priority(params[:role])
      redirect_to admin_roles_path, flash: { alert: I18n.t("administrator.roles.invalid_order") }
    end
  end

  # POST /admin/role/:role_id
  # This method updates the permissions assigned to a role
  def update_role
    role = Role.find(params[:role_id])
    flash[:alert] = I18n.t("administrator.roles.invalid_update") unless update_permissions(role)
    redirect_to admin_roles_path(selected_role: role.id)
  end

  # DELETE admins/role/:role_id
  # This deletes a role
  def delete_role
    role = Role.find(params[:role_id])

    # Make sure no users are assigned to the role and the role isn't a reserved role
    # before deleting
    if role.users.count.positive?
      flash[:alert] = I18n.t("administrator.roles.role_has_users", user_count: role.users.count)
      return redirect_to admin_roles_path(selected_role: role.id)
    elsif Role::RESERVED_ROLE_NAMES.include?(role) || role.provider != @user_domain ||
          role.priority <= current_user.highest_priority_role.priority
      return redirect_to admin_roles_path(selected_role: role.id)
    else
      role.role_permissions.delete_all
      role.delete
    end

    redirect_to admin_roles_path
  end

  private

  def find_user
    @user = User.where(uid: params[:user_uid]).includes(:roles).first
  end

  # Verifies that admin is an administrator of the user in the action
  def verify_admin_of_user
    redirect_to admins_path,
      flash: { alert: I18n.t("administrator.flash.unauthorized") } unless current_user.admin_of?(@user)
  end

  # Gets the list of users based on your configuration
  def user_list
    initial_list = if current_user.has_role? :super_admin
      User.where.not(id: current_user.id)
    else
      User.without_role(:super_admin).where.not(id: current_user.id)
    end

    if Rails.configuration.loadbalanced_configuration
      initial_list.where(provider: @user_domain)
                  .admins_search(@search, @role)
                  .admins_order(@order_column, @order_direction)
    else
      initial_list.admins_search(@search, @role)
                  .admins_order(@order_column, @order_direction)
    end
  end

  # Creates the invite if it doesn't exist, or updates the updated_at time if it does
  def create_or_update_invite(email)
    invite = Invitation.find_by(email: email, provider: @user_domain)

    # Invite already exists
    if invite.present?
      # Updates updated_at to now
      invite.touch
    else
      # Creates invite
      invite = Invitation.create(email: email, provider: @user_domain)
    end

    invite
  end
end
