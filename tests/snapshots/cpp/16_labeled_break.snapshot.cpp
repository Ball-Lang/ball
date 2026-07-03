
namespace {


} // namespace

int main() {
    auto found = BallDyn(static_cast<int64_t>(0));
    for (auto i = static_cast<int64_t>(1); (i <= static_cast<int64_t>(5)); ball_assign(i, (i + static_cast<int64_t>(1)))) {
        for (auto j = static_cast<int64_t>(1); (j <= static_cast<int64_t>(5)); ball_assign(j, (j + static_cast<int64_t>(1)))) {
            if (((i * j) == static_cast<int64_t>(12))) {
                ball_assign(found, ((i * static_cast<int64_t>(100)) + j));
                goto __ball_break_outer;
            }
        }
        __ball_continue_outer:;
    }
    __ball_break_outer:;
    std::cout << ball_to_string(ball_to_string(found)) << std::endl;
    return 0;
}
