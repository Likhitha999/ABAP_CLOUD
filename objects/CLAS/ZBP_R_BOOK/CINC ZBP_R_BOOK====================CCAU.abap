*"* use this source file for your ABAP unit test classes
*----------------------------------------------------------------------*
* ABAP Unit tests for the behavior implementation of ZR_BOOK
*
* - The RAP transactional buffer is replaced by a test double
*   (CL_BOTD_TXBUFDBL_BO_TEST_ENV), so READ/MODIFY ENTITIES inside the
*   handler work on test data only.
* - Table ZBOOK_A is replaced by an Open SQL test double
*   (CL_OSQL_TEST_ENVIRONMENT) for the SELECT MAX( book_id ) in
*   setInitialValues.
* - Handler methods are called directly; nothing is written to the DB.
*----------------------------------------------------------------------*
* Friendship: lhc_book declares FRIENDS ltc_book_handler (implementations include)

CLASS ltc_book_handler DEFINITION FINAL
  FOR TESTING DURATION SHORT RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    CONSTANTS:
      c_available TYPE c LENGTH 1 VALUE 'A',
      c_borrowed  TYPE c LENGTH 1 VALUE 'B'.

    CLASS-DATA bo_env  TYPE REF TO if_botd_txbufdbl_bo_test_env.
    CLASS-DATA sql_env TYPE REF TO if_osql_test_environment.

    DATA cut TYPE REF TO lhc_book.

    CLASS-METHODS class_setup.
    CLASS-METHODS class_teardown.
    METHODS setup.
    METHODS teardown.

    "! Creates a book in the transactional buffer double, returns its UUID
    METHODS create_book
      IMPORTING i_book_id       TYPE zr_book-BookID OPTIONAL
                i_status        TYPE zr_book-Status OPTIONAL
                i_price         TYPE zr_book-Price OPTIONAL
                i_currency      TYPE zr_book-CurrencyCode OPTIONAL
      RETURNING VALUE(r_uuid)   TYPE zr_book-BookUUID.

    METHODS read_book
      IMPORTING i_uuid        TYPE zr_book-BookUUID
      RETURNING VALUE(r_book) TYPE zr_book.

    " authorization
    METHODS global_auth_allows_all     FOR TESTING.
    " instance features
    METHODS features_for_available     FOR TESTING.
    METHODS features_for_borrowed      FOR TESTING.
    " actions
    METHODS mark_borrowed_sets_status  FOR TESTING.
    METHODS mark_available_sets_status FOR TESTING.
    " determination
    METHODS initial_values_assigned    FOR TESTING.
    METHODS existing_id_not_overwritten FOR TESTING.
    " validation
    METHODS negative_price_rejected    FOR TESTING.
    METHODS price_without_currency     FOR TESTING.
    METHODS valid_price_accepted       FOR TESTING.
    METHODS zero_price_no_currency_ok  FOR TESTING.
ENDCLASS.


CLASS ltc_book_handler IMPLEMENTATION.

  METHOD class_setup.
    bo_env = cl_botd_txbufdbl_bo_test_env=>create(
               environment_config = cl_botd_txbufdbl_bo_test_env=>prepare_environment_config(
                                      )->set_bdef_dependencies( VALUE #( ( 'ZR_BOOK' ) ) ) ).
    sql_env = cl_osql_test_environment=>create( i_dependency_list = VALUE #( ( 'ZBOOK_A' ) ) ).
  ENDMETHOD.

  METHOD class_teardown.
    bo_env->destroy( ).
    sql_env->destroy( ).
  ENDMETHOD.

  METHOD setup.
    CREATE OBJECT cut FOR TESTING.
  ENDMETHOD.

  METHOD teardown.
    ROLLBACK ENTITIES.                                  "#EC CI_ROLLBACK
    bo_env->clear_doubles( ).
    sql_env->clear_doubles( ).
  ENDMETHOD.

  METHOD create_book.
    " IN LOCAL MODE: the test class belongs to the behavior pool, so it may
    " fill read-only fields (BookID, Status) when preparing test data.
    MODIFY ENTITIES OF zr_book IN LOCAL MODE
      ENTITY Book
        CREATE FIELDS ( BookID Title Author Price CurrencyCode Status )
        WITH VALUE #( ( %cid         = 'NEW_BOOK'
                        BookID       = i_book_id
                        Title        = 'Test Book'
                        Author       = 'Test Author'
                        Price        = i_price
                        CurrencyCode = i_currency
                        Status       = i_status ) )
      MAPPED DATA(mapped)
      FAILED DATA(failed).

    cl_abap_unit_assert=>assert_initial( act = failed msg = 'Test data could not be created' ).
    r_uuid = mapped-book[ 1 ]-BookUUID.
  ENDMETHOD.

  METHOD read_book.
    READ ENTITIES OF zr_book
      ENTITY Book
        ALL FIELDS WITH VALUE #( ( BookUUID = i_uuid ) )
      RESULT DATA(books).

    cl_abap_unit_assert=>assert_equals( act = lines( books ) exp = 1 msg = 'Book not found' ).
    r_book = CORRESPONDING #( books[ 1 ] ).
  ENDMETHOD.

  "--------------------------------------------------------------------
  " Authorization
  "--------------------------------------------------------------------
  METHOD global_auth_allows_all.
    DATA requested TYPE STRUCTURE FOR GLOBAL AUTHORIZATION REQUEST zr_book\\book.
    DATA result    TYPE STRUCTURE FOR GLOBAL AUTHORIZATION RESULT zr_book\\book.
    DATA reported  TYPE RESPONSE FOR REPORTED EARLY zr_book.

    requested = VALUE #( %create = if_abap_behv=>mk-on
                         %update = if_abap_behv=>mk-on
                         %delete = if_abap_behv=>mk-on ).

    cut->get_global_authorizations( EXPORTING requested_authorizations = requested
                                    CHANGING  result                   = result
                                              reported                 = reported ).

    cl_abap_unit_assert=>assert_equals( act = result-%create exp = if_abap_behv=>auth-allowed ).
    cl_abap_unit_assert=>assert_equals( act = result-%update exp = if_abap_behv=>auth-allowed ).
    cl_abap_unit_assert=>assert_equals( act = result-%delete exp = if_abap_behv=>auth-allowed ).
  ENDMETHOD.

  "--------------------------------------------------------------------
  " Instance features
  "--------------------------------------------------------------------
  METHOD features_for_available.
    DATA result   TYPE TABLE FOR INSTANCE FEATURES RESULT zr_book\\book.
    DATA failed   TYPE RESPONSE FOR FAILED EARLY zr_book.
    DATA reported TYPE RESPONSE FOR REPORTED EARLY zr_book.

    DATA(uuid) = create_book( i_status = c_available ).

    cut->get_instance_features(
      EXPORTING keys               = VALUE #( ( BookUUID = uuid ) )
                requested_features = VALUE #( %action-markAvailable = if_abap_behv=>mk-on
                                              %action-markBorrowed  = if_abap_behv=>mk-on )
      CHANGING  result             = result
                failed             = failed
                reported           = reported ).

    cl_abap_unit_assert=>assert_equals( act = lines( result ) exp = 1 ).
    cl_abap_unit_assert=>assert_equals( act = result[ 1 ]-%action-markAvailable
                                        exp = if_abap_behv=>fc-o-disabled
                                        msg = 'markAvailable must be disabled for an available book' ).
    cl_abap_unit_assert=>assert_equals( act = result[ 1 ]-%action-markBorrowed
                                        exp = if_abap_behv=>fc-o-enabled
                                        msg = 'markBorrowed must be enabled for an available book' ).
  ENDMETHOD.

  METHOD features_for_borrowed.
    DATA result   TYPE TABLE FOR INSTANCE FEATURES RESULT zr_book\\book.
    DATA failed   TYPE RESPONSE FOR FAILED EARLY zr_book.
    DATA reported TYPE RESPONSE FOR REPORTED EARLY zr_book.

    DATA(uuid) = create_book( i_status = c_borrowed ).

    cut->get_instance_features(
      EXPORTING keys               = VALUE #( ( BookUUID = uuid ) )
                requested_features = VALUE #( %action-markAvailable = if_abap_behv=>mk-on
                                              %action-markBorrowed  = if_abap_behv=>mk-on )
      CHANGING  result             = result
                failed             = failed
                reported           = reported ).

    cl_abap_unit_assert=>assert_equals( act = lines( result ) exp = 1 ).
    cl_abap_unit_assert=>assert_equals( act = result[ 1 ]-%action-markAvailable
                                        exp = if_abap_behv=>fc-o-enabled
                                        msg = 'markAvailable must be enabled for a borrowed book' ).
    cl_abap_unit_assert=>assert_equals( act = result[ 1 ]-%action-markBorrowed
                                        exp = if_abap_behv=>fc-o-disabled
                                        msg = 'markBorrowed must be disabled for a borrowed book' ).
  ENDMETHOD.

  "--------------------------------------------------------------------
  " Actions
  "--------------------------------------------------------------------
  METHOD mark_borrowed_sets_status.
    DATA result   TYPE TABLE FOR ACTION RESULT zr_book\\book~markBorrowed.
    DATA mapped   TYPE RESPONSE FOR MAPPED EARLY zr_book.
    DATA failed   TYPE RESPONSE FOR FAILED EARLY zr_book.
    DATA reported TYPE RESPONSE FOR REPORTED EARLY zr_book.

    DATA(uuid) = create_book( i_status = c_available ).

    cut->markBorrowed( EXPORTING keys     = VALUE #( ( BookUUID = uuid ) )
                       CHANGING  result   = result
                                 mapped   = mapped
                                 failed   = failed
                                 reported = reported ).

    cl_abap_unit_assert=>assert_initial( failed ).
    cl_abap_unit_assert=>assert_equals( act = lines( result ) exp = 1 ).
    cl_abap_unit_assert=>assert_equals( act = result[ 1 ]-%param-Status exp = c_borrowed
                                        msg = 'Action result must carry the new status' ).
    cl_abap_unit_assert=>assert_equals( act = read_book( uuid )-Status exp = c_borrowed
                                        msg = 'Status must be updated in the buffer' ).
  ENDMETHOD.

  METHOD mark_available_sets_status.
    DATA result   TYPE TABLE FOR ACTION RESULT zr_book\\book~markAvailable.
    DATA mapped   TYPE RESPONSE FOR MAPPED EARLY zr_book.
    DATA failed   TYPE RESPONSE FOR FAILED EARLY zr_book.
    DATA reported TYPE RESPONSE FOR REPORTED EARLY zr_book.

    DATA(uuid) = create_book( i_status = c_borrowed ).

    cut->markAvailable( EXPORTING keys     = VALUE #( ( BookUUID = uuid ) )
                        CHANGING  result   = result
                                  mapped   = mapped
                                  failed   = failed
                                  reported = reported ).

    cl_abap_unit_assert=>assert_initial( failed ).
    cl_abap_unit_assert=>assert_equals( act = lines( result ) exp = 1 ).
    cl_abap_unit_assert=>assert_equals( act = result[ 1 ]-%param-Status exp = c_available
                                        msg = 'Action result must carry the new status' ).
    cl_abap_unit_assert=>assert_equals( act = read_book( uuid )-Status exp = c_available
                                        msg = 'Status must be updated in the buffer' ).
  ENDMETHOD.

  "--------------------------------------------------------------------
  " Determination setInitialValues
  "--------------------------------------------------------------------
  METHOD initial_values_assigned.
    DATA reported TYPE RESPONSE FOR REPORTED LATE zr_book.
    DATA db_rows  TYPE STANDARD TABLE OF zbook_a WITH EMPTY KEY.
    DATA exp_id_1 TYPE zr_book-BookID.
    DATA exp_id_2 TYPE zr_book-BookID.

    " Highest persisted Book ID is 41
    db_rows = VALUE #( ( book_uuid = CONV sysuuid_x16( 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA01' ) book_id = '00000007' )
                       ( book_uuid = CONV sysuuid_x16( 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA02' ) book_id = '00000041' ) ).
    sql_env->insert_test_data( db_rows ).

    DATA(uuid_1) = create_book( ).
    DATA(uuid_2) = create_book( ).

    cut->setInitialValues( EXPORTING keys     = VALUE #( ( BookUUID = uuid_1 ) ( BookUUID = uuid_2 ) )
                           CHANGING  reported = reported ).

    DATA(book_1) = read_book( uuid_1 ).
    DATA(book_2) = read_book( uuid_2 ).

    exp_id_1 = 42.
    exp_id_2 = 43.
    cl_abap_unit_assert=>assert_equals( act = book_1-BookID exp = exp_id_1 msg = 'First new book gets MAX + 1' ).
    cl_abap_unit_assert=>assert_equals( act = book_2-BookID exp = exp_id_2 msg = 'Second new book gets MAX + 2' ).
    cl_abap_unit_assert=>assert_equals( act = book_1-Status exp = c_available msg = 'Default status is Available' ).
    cl_abap_unit_assert=>assert_equals( act = book_2-Status exp = c_available msg = 'Default status is Available' ).
  ENDMETHOD.

  METHOD existing_id_not_overwritten.
    DATA reported TYPE RESPONSE FOR REPORTED LATE zr_book.
    DATA db_rows  TYPE STANDARD TABLE OF zbook_a WITH EMPTY KEY.
    DATA exp_id   TYPE zr_book-BookID.

    db_rows = VALUE #( ( book_uuid = CONV sysuuid_x16( 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA03' ) book_id = '00000099' ) ).
    sql_env->insert_test_data( db_rows ).

    exp_id = 5.
    DATA(uuid) = create_book( i_book_id = exp_id i_status = c_borrowed ).

    cut->setInitialValues( EXPORTING keys     = VALUE #( ( BookUUID = uuid ) )
                           CHANGING  reported = reported ).

    DATA(book) = read_book( uuid ).
    cl_abap_unit_assert=>assert_equals( act = book-BookID exp = exp_id
                                        msg = 'An existing Book ID must not be replaced' ).
    cl_abap_unit_assert=>assert_equals( act = book-Status exp = c_borrowed
                                        msg = 'Status of a book with an ID must not be reset' ).
  ENDMETHOD.

  "--------------------------------------------------------------------
  " Validation validatePrice
  "--------------------------------------------------------------------
  METHOD negative_price_rejected.
    DATA failed   TYPE RESPONSE FOR FAILED LATE zr_book.
    DATA reported TYPE RESPONSE FOR REPORTED LATE zr_book.

    DATA(uuid) = create_book( i_price = '-1.00' i_currency = 'EUR' ).

    cut->validatePrice( EXPORTING keys     = VALUE #( ( BookUUID = uuid ) )
                        CHANGING  failed   = failed
                                  reported = reported ).

    cl_abap_unit_assert=>assert_equals( act = lines( failed-book ) exp = 1 msg = 'Negative price must fail' ).
    cl_abap_unit_assert=>assert_equals( act = failed-book[ 1 ]-BookUUID exp = uuid ).
    cl_abap_unit_assert=>assert_equals( act = lines( reported-book ) exp = 1 ).
    cl_abap_unit_assert=>assert_equals( act = reported-book[ 1 ]-%element-Price exp = if_abap_behv=>mk-on
                                        msg = 'Message must point to field Price' ).
    cl_abap_unit_assert=>assert_equals( act = reported-book[ 1 ]-%msg->m_severity
                                        exp = if_abap_behv_message=>severity-error ).
  ENDMETHOD.

  METHOD price_without_currency.
    DATA failed   TYPE RESPONSE FOR FAILED LATE zr_book.
    DATA reported TYPE RESPONSE FOR REPORTED LATE zr_book.

    DATA(uuid) = create_book( i_price = '19.99' ).

    cut->validatePrice( EXPORTING keys     = VALUE #( ( BookUUID = uuid ) )
                        CHANGING  failed   = failed
                                  reported = reported ).

    cl_abap_unit_assert=>assert_equals( act = lines( failed-book ) exp = 1 msg = 'Price without currency must fail' ).
    cl_abap_unit_assert=>assert_equals( act = lines( reported-book ) exp = 1 ).
    cl_abap_unit_assert=>assert_equals( act = reported-book[ 1 ]-%element-CurrencyCode exp = if_abap_behv=>mk-on
                                        msg = 'Message must point to field CurrencyCode' ).
  ENDMETHOD.

  METHOD valid_price_accepted.
    DATA failed   TYPE RESPONSE FOR FAILED LATE zr_book.
    DATA reported TYPE RESPONSE FOR REPORTED LATE zr_book.

    DATA(uuid) = create_book( i_price = '19.99' i_currency = 'EUR' ).

    cut->validatePrice( EXPORTING keys     = VALUE #( ( BookUUID = uuid ) )
                        CHANGING  failed   = failed
                                  reported = reported ).

    cl_abap_unit_assert=>assert_initial( act = failed   msg = 'Valid price must not fail' ).
    cl_abap_unit_assert=>assert_initial( act = reported msg = 'Valid price must not report messages' ).
  ENDMETHOD.

  METHOD zero_price_no_currency_ok.
    DATA failed   TYPE RESPONSE FOR FAILED LATE zr_book.
    DATA reported TYPE RESPONSE FOR REPORTED LATE zr_book.

    DATA(uuid) = create_book( ).

    cut->validatePrice( EXPORTING keys     = VALUE #( ( BookUUID = uuid ) )
                        CHANGING  failed   = failed
                                  reported = reported ).

    cl_abap_unit_assert=>assert_initial( act = failed msg = 'A book without price needs no currency' ).
  ENDMETHOD.

ENDCLASS.
