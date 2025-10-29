from django.contrib import admin
from django.urls import reverse, path
from django.utils.html import format_html
from django.shortcuts import redirect, render
from django.db import models  # <-- Add this import
from django import forms  # <-- Add this import
from .models import User, BooksLog, Login, ReturnDesk, Department, Notification, DeveloperNotification, BooksDetail  # Added BooksDetail

# Register your models here.

@admin.register(User)
class UserAdmin(admin.ModelAdmin):
    list_display = (
        'barcode_number', 'first_name', 'last_name', 'phone_number', 'email', 'department',
        'issued_book_list', 'wish_list', 'due_fine'  # show Due Fine column
    )
    search_fields = ('barcode_number', 'first_name', 'last_name', 'email', 'phone_number', 'department')
    actions = ['view_profile_action', 'view_wishlist_action', 'view_bookhold_action']

    def profile_link(self, obj):
        url = reverse('admin:novalib_user_change', args=[obj.pk])
        return format_html('<a href="{}">Profile</a>', url)
    profile_link.short_description = 'Profile'

    def wishlist_link(self, obj):
        # Filter BooksLog by ManyToMany wishlist relation
        url = reverse('admin:novalib_bookslog_changelist') + f'?wishlist__id__exact={obj.pk}'
        return format_html('<a href="{}">Wishlist</a>', url)
    wishlist_link.short_description = 'Wishlist'

    def bookhold_link(self, obj):
        url = reverse('admin:novalib_booksdetail_changelist') + f'?user__id__exact={obj.pk}&avalible=0'
        return format_html('<a href="{}">Book Hold</a>', url)
    bookhold_link.short_description = 'Book Hold'

    def view_profile_action(self, request, queryset):
        if queryset.count() == 1:
            obj = queryset.first()
            url = reverse('admin:novalib_user_change', args=[obj.pk])
            return redirect(url)
        else:
            self.message_user(request, "Please select exactly one user to view profile.")
    view_profile_action.short_description = "View Profile"

    def view_wishlist_action(self, request, queryset):
        if queryset.count() == 1:
            obj = queryset.first()
            # Show only wishlist books for the selected user via M2M field
            wishlist_books = BooksLog.objects.filter(wishlist=obj)
            context = dict(
                self.admin_site.each_context(request),
                user=obj,
                wishlist_books=wishlist_books,
            )
            return render(request, "admin/wishlist_list.html", context)
        else:
            self.message_user(request, "Please select exactly one user to view wishlist.")
    view_wishlist_action.short_description = "View Wishlist"

    def view_bookhold_action(self, request, queryset):
        if queryset.count() == 1:
            obj = queryset.first()
            # Show only books held by the selected user (avalible=False) from BooksDetail
            bookholds = BooksDetail.objects.filter(user=obj, avalible=False)
            context = dict(
                self.admin_site.each_context(request),
                user=obj,
                bookholds=bookholds,
            )
            return render(request, "admin/bookhold_list.html", context)
        else:
            self.message_user(request, "Please select exactly one user to view book hold.")
    view_bookhold_action.short_description = "View Book Hold"

    def issued_book_list(self, obj):
        # List of books currently issued to the user from BooksDetail (any assigned book)
        titles = BooksDetail.objects.filter(user=obj).values_list('book_title', flat=True).distinct()
        return ", ".join(titles) if titles else "-"
    issued_book_list.short_description = "Issued Book List"

    def wish_list(self, obj):
        # List of books in the user's wishlist
        return ", ".join(
            BooksLog.objects.filter(wishlist=obj).values_list('book_title', flat=True)
        ) or "-"
    wish_list.short_description = "Wish List"

    # New: Due Fine column (sum of fines from ReturnDesk for the user)
    def due_fine(self, obj):
        total_fine = ReturnDesk.objects.filter(student=obj).aggregate(models.Sum('fine'))['fine__sum']
        return total_fine if total_fine else 0
    due_fine.short_description = "Due Fine"

    # Keep existing payment method (not shown in list_display anymore)
    def payment(self, obj):
        # Sum of fines for the user in ReturnDesk
        total_fine = ReturnDesk.objects.filter(student=obj).aggregate(models.Sum('fine'))['fine__sum']
        return total_fine if total_fine else 0
    payment.short_description = "Payment"

@admin.register(BooksLog)
class BooksLogAdmin(admin.ModelAdmin):
    list_display = ('book_title', 'available_count', 'book_count', 'get_wishlist_users', 'auther', 'availability')  # added 'book_count' after 'available_count'
    search_fields = ('wishlist__barcode_number', 'book_title', 'auther')  # Removed user__barcode_number
    fieldsets = (
        (None, {
            'fields': ('wishlist', 'book_title', 'auther', 'avalible')
        }),
    )

    def get_wishlist_users(self, obj):
        return ", ".join([f"{user.first_name} {user.last_name}" for user in obj.wishlist.all()])
    get_wishlist_users.short_description = 'Wishlist Users'

    def view_available_books(self, request, queryset):
        from django.shortcuts import render
        available_books = BooksLog.objects.filter(avalible=True)
        context = dict(
            self.admin_site.each_context(request),
            books=available_books,
            title="Available Books"
        )
        return render(request, "admin/available_books.html", context)
    view_available_books.short_description = "Show Available Books (separate page)"

    def view_unavailable_books(self, request, queryset):
        from django.shortcuts import render
        unavailable_books = BooksLog.objects.filter(avalible=False)
        context = dict(
            self.admin_site.each_context(request),
            books=unavailable_books,
            title="Unavailable Books"
        )
        return render(request, "admin/unavailable_books.html", context)
    view_unavailable_books.short_description = "Show Unavailable Books (separate page)"

    def available_count(self, obj):
        # Count BooksDetail entries for same title+author that have no user and are marked available
        return BooksDetail.objects.filter(book_title=obj.book_title, auther=obj.auther, user__isnull=True, avalible=True).count()
    available_count.short_description = 'Available Count'

    def book_count(self, obj):
        # Total copies for the same title+author (regardless of user/availability)
        return BooksDetail.objects.filter(book_title=obj.book_title, auther=obj.auther).count()
    book_count.short_description = 'Book Count'

    def availability(self, obj):
        # True when at least one unassigned available copy exists, False when none
        return self.available_count(obj) > 0
    availability.short_description = 'Availability'
    availability.boolean = True

@admin.register(Login)
class LoginAdmin(admin.ModelAdmin):
    list_display = ('id', 'user', 'login_time', 'ip_address', 'authorized')  # Corrected 'authorized'
    search_fields = ('user__barcode_number', 'ip_address')

    def get_urls(self):
        urls = super().get_urls()
        custom_urls = [
            path(
                "bookhold/<int:user_id>/",
                self.admin_site.admin_view(self.bookhold_view),
                name="novalib_login_bookhold",
            )
        ]
        return custom_urls + urls

    def bookhold_view(self, request, user_id):
        user = User.objects.get(pk=user_id)
        # Show all BooksDetail for this user where avalible=False (book hold)
        bookholds = BooksDetail.objects.filter(user=user, avalible=False)
        context = dict(
            self.admin_site.each_context(request),
            user=user,
            bookholds=bookholds,
        )
        return render(request, "admin/bookhold_list.html", context)

@admin.register(ReturnDesk)
class ReturnDeskAdmin(admin.ModelAdmin):
    list_display = (
        'student_barcode', 'student_name', 'book', 'fine', 'otp', 'otp_expired'
    )
    search_fields = ('student__barcode_number', 'student__first_name', 'student__last_name', 'book', 'otp')

    # Detect if ReturnDesk.book is a ForeignKey to BooksLog
    _book_field = ReturnDesk._meta.get_field('book')
    _is_book_fk = isinstance(_book_field, models.ForeignKey) and getattr(_book_field.remote_field, 'model', None) is BooksLog

    # If FK -> enable autocomplete, otherwise use a custom form with choices from BooksLog
    if _is_book_fk:
        autocomplete_fields = ['book']
    else:
        class ReturnDeskForm(forms.ModelForm):
            # Replace raw input with a dropdown fed from BooksDetail
            book = forms.ChoiceField(required=True, choices=[])

            class Meta:
                model = ReturnDesk
                fields = '__all__'

            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                # Try to scope options to the selected student, else show all
                student_id = self.initial.get('student') or getattr(self.instance, 'student_id', None)
                qs = BooksDetail.objects.all()
                if student_id:
                    qs = qs.filter(user_id=student_id, avalible=False)
                # Build choices (value=title, label=title + barcode)
                seen = set()
                choices = []
                for b in qs.order_by('-issued_date')[:500]:
                    title = getattr(b, 'book_title', '') or ''
                    if title in seen:
                        continue
                    seen.add(title)
                    barcode = getattr(b, 'book_barcode', '') or ''
                    label = f"{title} ({barcode})" if barcode else title
                    choices.append((title, label))
                self.fields['book'].choices = choices

        form = ReturnDeskForm

    # When book is FK, filter its queryset to the selected student (if provided)
    def formfield_for_foreignkey(self, db_field, request, **kwargs):
        if self._is_book_fk and db_field.name == 'book':
            qs = BooksDetail.objects.all()
            # Try to grab student id from GET (add form) or POST (change form)
            student_id = request.GET.get('student') or request.POST.get('student')
            if student_id:
                qs = qs.filter(user_id=student_id, avalible=False)
            kwargs['queryset'] = qs.order_by('-issued_date')
        return super().formfield_for_foreignkey(db_field, request, **kwargs)

    def student_barcode(self, obj):
        return obj.student.barcode_number
    student_barcode.short_description = 'Student Barcode Number'

    def student_name(self, obj):
        return f"{obj.student.first_name} {obj.student.last_name}"
    student_name.short_description = 'Name'

@admin.register(Department)
class DepartmentAdmin(admin.ModelAdmin):
    list_display = ('name', 'total_users')
    search_fields = ('name',)
    actions = ['view_users']

    def total_users(self, obj):
        return User.objects.filter(department=obj).count()  # Filter by the Department object itself
    total_users.short_description = 'Total Users'

    def view_users(self, request, queryset):
        if queryset.count() == 1:
            department = queryset.first()
            users = User.objects.filter(department=department)
            context = dict(
                self.admin_site.each_context(request),
                department=department,
                users=users,
            )
            return render(request, "admin/department_users.html", context)
        else:
            self.message_user(request, "Please select exactly one department to view users.")
    view_users.short_description = "View Users from Selected Department"

@admin.register(Notification)
class NotificationAdmin(admin.ModelAdmin):
    list_display = ('notification_id', 'title', 'uploaded_by', 'message', 'uploaded_image')  # show notification_id
    search_fields = ('notification_id', 'title', 'uploaded_by__username', 'message')
    readonly_fields = ('uploaded_image_preview',)

    def uploaded_image_preview(self, obj):
        if obj.uploaded_image:
            return format_html('<img src="{}" style="max-height:100px;"/>', obj.uploaded_image.url)
        return "-"
    uploaded_image_preview.short_description = "Image Preview"

    def delete_model(self, request, obj):
        # Delete the image file from storage if it exists
        if obj.uploaded_image and obj.uploaded_image.storage.exists(obj.uploaded_image.name):
            obj.uploaded_image.delete(save=False)
        super().delete_model(request, obj)

@admin.register(DeveloperNotification)
class DeveloperNotificationAdmin(admin.ModelAdmin):
    list_display = ('notification_id', 'title', 'uploaded_by', 'message', 'uploaded_image')  # Show notification_id
    search_fields = ('notification_id', 'title', 'uploaded_by__username', 'message')
    readonly_fields = ('uploaded_image_preview',)

    def uploaded_image_preview(self, obj):
        if obj.uploaded_image:
            return format_html('<img src="{}" style="max-height:100px;"/>', obj.uploaded_image.url)
        return "-"
    uploaded_image_preview.short_description = "Image Preview"

    def delete_model(self, request, obj):
        # Delete the image file from storage if it exists
        if obj.uploaded_image and obj.uploaded_image.storage.exists(obj.uploaded_image.name):
            obj.uploaded_image.delete(save=False)
        super().delete_model(request, obj)

@admin.register(BooksDetail)
class BooksDetailAdmin(admin.ModelAdmin):
    list_display = ('book_barcode', 'get_title_author', 'user', 'is_available', 'get_issued_date', 'get_return_date')  # use admin method for availability
    search_fields = ('book_barcode', 'book_title', 'auther')

    def get_title_author(self, obj):
        return f"{obj.book_title} ({obj.auther})"
    get_title_author.short_description = 'Title and Author'

    def get_issued_date(self, obj):
        return getattr(obj, 'issued_date', None)
    get_issued_date.short_description = 'Issued Date'

    def get_return_date(self, obj):
        return getattr(obj, 'return_date', None)
    get_return_date.short_description = 'Return Date'

    def is_available(self, obj):
        # If assigned to a user -> unavailable. Otherwise fall back to stored avalible flag.
        if getattr(obj, 'user', None):
            return False
        return bool(obj.avalible)
    is_available.short_description = 'Available'
    is_available.boolean = True

    # use default queryset (BooksDetail.objects.all()) so admin shows actual BooksDetail rows

    class BooksDetailForm(forms.ModelForm):
        book_title_author = forms.ChoiceField(choices=[], required=True, label="Book title and Author")

        class Meta:
            model = BooksDetail
            fields = '__all__'

        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            # Build unique (title, author) pairs from BooksLog
            pairs = BooksLog.objects.values_list('book_title', 'auther').distinct()
            self.fields['book_title_author'].choices = [
                (f"{title}|||{author}", f"{title} ({author})") for title, author in pairs
            ]
            # Set initial values if editing
            if self.instance and self.instance.pk:
                self.fields['book_title_author'].initial = f"{self.instance.book_title}|||{self.instance.auther}"

        def clean(self):
            cleaned_data = super().clean()
            value = cleaned_data.get('book_title_author')
            if value:
                title, author = value.split('|||', 1)
                # set on instance so save works even when fields are removed from form
                self.instance.book_title = title
                self.instance.auther = author
            return cleaned_data

        def save(self, commit=True):
            # ensure instance has book_title/auther from dropdown before saving
            value = self.cleaned_data.get('book_title_author')
            if value:
                title, author = value.split('|||', 1)
                self.instance.book_title = title
                self.instance.auther = author
            return super().save(commit=commit)

    form = BooksDetailForm

    def get_form(self, request, obj=None, **kwargs):
        form = super().get_form(request, obj, **kwargs)
        # Remove book_title and auther fields from the form (handled by dropdown)
        form.base_fields.pop('book_title', None)
        form.base_fields.pop('auther', None)
        return form
